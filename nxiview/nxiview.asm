; nxiview.dot - display an NXI image on Layer 2.
; Vibe-coded by RCL/VVG, with the testing and debugging support from Pinkie_Pie
;
; Sizes (after optional 128B PLUS3DOS header):
;   49152  256x192x256
;   49664  256x192x256 + 512B palette
;   81920  320x256x256 or 640x256x16 (no palette; mode picked by nibble probe)
;   81952  640x256x16 + 32B palette
;   82432  320x256x256 + 512B palette
;
; M toggles 320 / 640. Any other key exits.

	device ZXSPECTRUMNEXT
	org $2000

;------------------------------- equates -------------------------------

M_P3DOS equ $94
F_OPEN  equ $9A
F_CLOSE equ $9B
F_READ  equ $9D
F_SEEK  equ $9F
F_FSTAT equ $A1

IDE_BANK         equ $01BD
RC_BANKTYPE_ZX   equ 0
RC_BANK_ALLOC    equ 1
RC_BANK_FREE     equ 3

FA_READ equ $01

NR_MMU3_6000     equ $53
NR_PALETTE_INDEX equ $40
NR_PALETTE_CTRL  equ $43
NR_PAL_VALUE_9B  equ $44
NR_L2_BANK       equ $12
NR_L2_SHADOW     equ $13
NR_DISPLAY_CTRL  equ $69
NR_L2_CTRL       equ $70
NR_L2_SCROLL_X_LO equ $16
NR_L2_SCROLL_Y    equ $17
NR_L2_SCROLL_X_HI equ $71
NR_CLIP_INDEX     equ $1C
NR_L2_CLIP        equ $18
NR_GLOBAL_TRANSPARENCY equ $14
NR_FALLBACK_COLOR equ $4A
NR_TURBO_MODE    equ $07
TURBO_28MHZ      equ %00000011

NR_SELECT_PORT   equ $243B
NR_DATA_PORT     equ $253B

; NR_L2_CTRL bits[5:4]: display resolution mode (00=256x192, 01=320x256, 10=640x256)
L2MODE_256x192   equ %00000000
L2MODE_320x256   equ %00010000
L2MODE_640x256   equ %00100000

;------------------------------- entry --------------------------------

Start:
	di
	ld (ArgPtr), hl
	ld (SavedSP), sp
	ld iy, $5C3A                    ; esxDOS API needs IY = sysvars base
	ei                              ; halt in WaitKey would otherwise lock

	; Initialise data that's past CodeEnd (not in SAVEBIN, so undefined).
	xor a
	ld (NeedProbe), a
	ld (AllocatedCount), a
	ld a, $E3
	ld (TransparentIdx), a

	call SaveRegs                   ; also switches CPU to 28 MHz

	ld hl, (ArgPtr)
	call ParseArg
	jp c, ErrUsage
	ld a, (FilenameBuf)
	or a
	jp z, ErrUsage                  ; defensive: empty buffer => usage

	; -h / -H / -? prints usage instead of trying to open the option as a file.
	cp '-'
	jr nz, .NotHelpOpt
	ld a, (FilenameBuf+1)
	cp 'h' : jp z, ErrUsage
	cp 'H' : jp z, ErrUsage
	cp '?' : jp z, ErrUsage
.NotHelpOpt:

	ld a, '*'                       ; default drive
	ld b, FA_READ
	ld hl, FilenameBuf
	rst $08 : db F_OPEN
	jp c, ErrOpen
	ld (FileHandle), a

	call MaybeSkipPlus3DosHeader
	jp c, ErrReadCloseFirst
	call GetPayloadSize
	jp c, ErrReadCloseFirst
	call DetermineMode
	jp c, ErrBadSize
	call ReadPalette
	jp c, ErrReadCloseFirst

	; Claim our own L2 banks via IDE_BANK so we don't stomp on the OS's.
	call AllocateL2Buffer
	jp c, ErrAlloc

	call SetL2Mode
	call ResetL2View
	call UploadPalette
	call SetTransparentColor        ; only needs the palette, set it up front

	nextreg NR_DISPLAY_CTRL, %10000000   ; display on - user sees progress

	call UploadImage
	jp c, ErrReadCloseFirst

	call BuildHistogram
	call ProbeNibbles
	call SetL2Mode                  ; reapply if ProbeNibbles flipped the mode

	call WaitKey

	call RestoreRegs
	call FreeL2Buffer
	ld a, (FileHandle)
	rst $08 : db F_CLOSE
	ei
	xor a
	ret

;----------------------------- subroutines ----------------------------

; HL = caller's arg ptr -> first token NUL-terminated in FilenameBuf. CF=1
; if empty or if any non-ASCII byte (>=128) appears -- guards against
; bit-7-terminated tokens that some callers (e.g. NextZXOS BASIC) emit.
ParseArg:
.SkipSpaces:
	ld a, (hl)
	cp ' '
	jr nz, .GotStart
	inc hl
	jr .SkipSpaces
.GotStart:
	or a
	jr z, .Empty
	cp 13
	jr z, .Empty
	cp 128
	jr nc, .Empty
	ld de, FilenameBuf

	cp '"'
	jr z, .Quoted
	cp 27h
	jr nz, .Copy
.Quoted:
	ld c, a                         ; remember quote char
	inc hl
.QCopy:
	ld a, (hl)
	or a    : jr z, .Done
	cp 13   : jr z, .Done
	cp c    : jr z, .Done
	cp 128  : jr nc, .Empty
	ld (de), a
	inc hl
	inc de
	jr .QCopy

.Copy:
	ld a, (hl)
	or a    : jr z, .Done
	cp 13   : jr z, .Done
	cp ' '  : jr z, .Done
	cp 128  : jr nc, .Empty
	ld (de), a
	inc hl
	inc de
	jr .Copy
.Done:
	xor a
	ld (de), a
	ld a, (FilenameBuf)
	or a
	jr z, .Empty
	xor a
	ret
.Empty:
	scf
	ret


; A = NextReg index -> A = value.
ReadNextReg:
	push bc
	ld bc, NR_SELECT_PORT
	out (c), a
	ld bc, NR_DATA_PORT
	in a, (c)
	pop bc
	ret


; Snapshot/restore every NextReg we touch so the caller's state survives.

	macro SAVENR addr, dst
		ld a, addr
		call ReadNextReg
		ld (dst), a
	endm

SaveRegs:
	SAVENR NR_TURBO_MODE,         SavedTurbo
	SAVENR NR_L2_BANK,            OrigL2Bank
	SAVENR NR_L2_SHADOW,          OrigL2Shadow
	SAVENR NR_L2_CTRL,            OrigL2Ctrl
	SAVENR NR_DISPLAY_CTRL,       OrigDisplayCtrl
	SAVENR NR_GLOBAL_TRANSPARENCY,OrigTransparency
	SAVENR NR_FALLBACK_COLOR,     OrigFallback
	SAVENR NR_PALETTE_CTRL,       OrigPalCtrl
	SAVENR NR_PALETTE_INDEX,      OrigPalIdx
	SAVENR NR_L2_SCROLL_X_LO,     OrigScrollX
	SAVENR NR_L2_SCROLL_Y,        OrigScrollY
	SAVENR NR_L2_SCROLL_X_HI,     OrigScrollXHi
	SAVENR NR_MMU3_6000,          OrigMmu3
	nextreg NR_CLIP_INDEX, %00000010    ; reset L2 clip read/write index
	SAVENR NR_L2_CLIP, OrigClipX1
	SAVENR NR_L2_CLIP, OrigClipX2
	SAVENR NR_L2_CLIP, OrigClipY1
	SAVENR NR_L2_CLIP, OrigClipY2

	nextreg NR_TURBO_MODE, TURBO_28MHZ
	ret


	macro RESTORENR src, addr
		ld a, (src)
		nextreg addr, a
	endm

RestoreRegs:
	; L2 bank base first, so we're not still pointed at banks we're about to free.
	RESTORENR OrigL2Bank,         NR_L2_BANK
	RESTORENR OrigL2Shadow,       NR_L2_SHADOW
	RESTORENR OrigL2Ctrl,         NR_L2_CTRL
	RESTORENR OrigDisplayCtrl,    NR_DISPLAY_CTRL
	RESTORENR OrigTransparency,   NR_GLOBAL_TRANSPARENCY
	RESTORENR OrigFallback,       NR_FALLBACK_COLOR
	RESTORENR OrigPalCtrl,        NR_PALETTE_CTRL
	RESTORENR OrigPalIdx,         NR_PALETTE_INDEX
	RESTORENR OrigScrollX,        NR_L2_SCROLL_X_LO
	RESTORENR OrigScrollY,        NR_L2_SCROLL_Y
	RESTORENR OrigScrollXHi,      NR_L2_SCROLL_X_HI
	RESTORENR OrigMmu3,           NR_MMU3_6000
	nextreg NR_CLIP_INDEX, %00000010
	RESTORENR OrigClipX1, NR_L2_CLIP
	RESTORENR OrigClipX2, NR_L2_CLIP
	RESTORENR OrigClipY1, NR_L2_CLIP
	RESTORENR OrigClipY2, NR_L2_CLIP
	RESTORENR SavedTurbo, NR_TURBO_MODE
	ret


; Allocate 10 contiguous, 16K-aligned 8K banks for our L2 front buffer
; via IDE_BANK ($01BD) through M_P3DOS. NextZXOS only owns 48KB of L2 by
; default, which isn't enough for 320/640 mode's 80KB front buffer, so we
; carve out our own range and program NR $12/$13 to point at it.
;
; IDE_BANK returns highest-available bank first, so consecutive allocs
; come back in descending order. We grab 11 banks then drop either the
; highest or the lowest so the lowest 8K bank is even (16K-aligned).
AllocateL2Buffer:
	xor a
	ld (AllocatedCount), a

	ld b, 11
	ld ix, AllocatedBanks
.AllocLoop:
	push bc
	push ix
	call IdeBankAlloc
	pop ix
	pop bc
	jr nc, .AllocFail
	ld (ix+0), a
	inc ix
	ld a, (AllocatedCount)
	inc a
	ld (AllocatedCount), a
	djnz .AllocLoop

	; Verify all 11 are descending consecutive.
	ld hl, AllocatedBanks
	ld a, (hl)
	inc hl
	ld b, 10
.CheckLoop:
	dec a
	cp (hl)
	jp nz, .AllocFail
	inc hl
	djnz .CheckLoop

	; H = AllocatedBanks[0] (highest). To 16K-align, drop top if H even else bottom.
	ld a, (AllocatedBanks)
	bit 0, a
	jr z, .UseBottom

	ld a, (AllocatedBanks+10)
	call IdeBankFree
	ld a, 10
	ld (AllocatedCount), a
	jr .Configure

.UseBottom:
	ld a, (AllocatedBanks)
	call IdeBankFree
	ld hl, AllocatedBanks+1
	ld de, AllocatedBanks
	ld bc, 10
	ldir
	ld a, 10
	ld (AllocatedCount), a

.Configure:
	ld a, (AllocatedBanks+9)
	srl a                           ; lowest 8K bank / 2 = 16K bank index
	ld (Layer2Bank16k), a
	nextreg NR_L2_BANK, a
	nextreg NR_L2_SHADOW, a
	or a
	ret

.AllocFail:
	call FreeL2Buffer
	scf
	ret


FreeL2Buffer:
	ld a, (AllocatedCount)
	or a
	ret z
	ld b, a
	ld ix, AllocatedBanks
.FreeLoop:
	push bc
	ld a, (ix+0)
	call IdeBankFree
	pop bc
	inc ix
	djnz .FreeLoop
	xor a
	ld (AllocatedCount), a
	ret


; CF=1 + A=8K bank ID on success, CF=0 on failure.
IdeBankAlloc:
	exx
	ld h, RC_BANKTYPE_ZX
	ld l, RC_BANK_ALLOC
	exx
	ld de, IDE_BANK
	ld c, 7
	rst $08 : db M_P3DOS
	ret nc                          ; M_P3DOS uses Fc=0 for error
	ld a, e
	scf
	ret


; A = 8K bank ID to free.
IdeBankFree:
	exx
	ld h, RC_BANKTYPE_ZX
	ld l, RC_BANK_FREE
	ld e, a                         ; A survives exx; copy to E'
	exx
	ld de, IDE_BANK
	ld c, 7
	rst $08 : db M_P3DOS
	ret


; Detect a 128-byte PLUS3DOS header; store 0 or 128 in PayloadStart and seek there.
MaybeSkipPlus3DosHeader:
	ld a, (FileHandle)
	ld hl, HeaderProbe              ; HL (not IX) from a dot command
	ld bc, 8
	rst $08 : db F_READ
	ret c

	ld hl, HeaderProbe
	ld de, Plus3DosSig
	ld b, 8
.Cmp:
	ld a, (de)
	cp (hl)
	jr nz, .NoHeader
	inc hl
	inc de
	djnz .Cmp

	ld de, 128
	jr .Seek
.NoHeader:
	ld de, 0
.Seek:
	ld (PayloadStart), de           ; save before seek consumes DE
	ld a, (FileHandle)
	ld bc, 0
	ld l, 0                         ; SEEK_SET (L from a dot command)
	rst $08 : db F_SEEK
	ret


; Read file size via F_FSTAT, subtract PayloadStart, store as PayloadSize{Lo,Hi}.
; F_SEEK has no SEEK_END mode, hence F_FSTAT.
GetPayloadSize:
	ld a, (FileHandle)
	ld hl, FStatBuf
	rst $08 : db F_FSTAT
	ret c
	ld de, (FStatBuf+7)             ; size low word
	ld hl, (FStatBuf+9)             ; size high word
	ld a, (PayloadStart)
	ld c, a
	ld a, e
	sub c
	ld e, a
	jr nc, .NoBorrow
	dec d
.NoBorrow:
	ld (PayloadSizeLo), de
	ld (PayloadSizeHi), hl

	ld de, (PayloadStart)
	ld a, (FileHandle)
	ld bc, 0
	ld l, 0                         ; SEEK_SET
	rst $08 : db F_SEEK
	ret


; Decode payload size into DisplayMode (0/1/2), PalEntries (0/16/256),
; ImageChunks (6/10) and NeedProbe. CF=1 if size is unrecognised.
DetermineMode:
	xor a : ld (NeedProbe), a

	ld hl, (PayloadSizeHi)
	ld de, (PayloadSizeLo)
	ld a, h : or l
	jr nz, .BigFamily

	; 49152 = 256x192, no palette
	ld a, d : cp $C0 : jr nz, .Try49664
	ld a, e : or a   : jr nz, .Try49664
	xor a : ld (DisplayMode), a
	ld hl, 0   : ld (PalEntries), hl
	ld a, 6    : ld (ImageChunks), a
	or a : ret

.Try49664:
	; 49664 = 256x192 + 256-entry palette
	ld a, d : cp $C2 : jr nz, .BadSize
	ld a, e : or a   : jr nz, .BadSize
	xor a : ld (DisplayMode), a
	ld hl, 256 : ld (PalEntries), hl
	ld a, 6    : ld (ImageChunks), a
	or a : ret

.BigFamily:
	ld a, h : or a : jr nz, .BadSize
	ld a, l : cp 1 : jr nz, .BadSize

	; 81920 = 320 or 640 (no palette, ambiguous - probe after upload)
	ld a, d : cp $40 : jr nz, .Try81952
	ld a, e : or a   : jr nz, .Try81952
	ld a, 1 : ld (DisplayMode), a
	ld hl, 0   : ld (PalEntries), hl
	ld a, 10   : ld (ImageChunks), a
	ld a, 1    : ld (NeedProbe), a
	or a : ret

.Try81952:
	; 81952 = 640x256x16 + 16-entry palette
	ld a, d : cp $40 : jr nz, .Try82432
	ld a, e : cp $20 : jr nz, .Try82432
	ld a, 2 : ld (DisplayMode), a
	ld hl, 16  : ld (PalEntries), hl
	ld a, 10   : ld (ImageChunks), a
	or a : ret

.Try82432:
	; 82432 = 320x256x256 + 256-entry palette
	ld a, d : cp $42 : jr nz, .BadSize
	ld a, e : or a   : jr nz, .BadSize
	ld a, 1 : ld (DisplayMode), a
	ld hl, 256 : ld (PalEntries), hl
	ld a, 10   : ld (ImageChunks), a
	or a : ret

.BadSize:
	scf
	ret


; Read PalEntries*2 bytes from file into PaletteBuf. No-op if PalEntries == 0.
ReadPalette:
	ld hl, (PalEntries)
	ld a, h : or l
	ret z
	add hl, hl
	ld b, h : ld c, l
	ld a, (FileHandle)
	ld hl, PaletteBuf
	rst $08 : db F_READ
	ret


; Upload PaletteBuf into L2 palette 0; install standard rainbow identity
; if the file had no palette. Mirrors the chosen palette into PaletteBuf
; and sets PalEntries=256 in the identity case so SetTransparentColor's
; bit-aware scan handles both paths uniformly.
UploadPalette:
	nextreg NR_PALETTE_CTRL, %00010000
	nextreg NR_PALETTE_INDEX, 0
	ld bc, (PalEntries)
	ld a, b : or c
	jr z, .Identity

	ld hl, PaletteBuf
.Loop:
	ld a, (hl) : inc hl
	nextreg NR_PAL_VALUE_9B, a
	ld a, (hl) : inc hl
	nextreg NR_PAL_VALUE_9B, a
	dec bc
	ld a, b : or c
	jr nz, .Loop
	ret

.Identity:
	; Standard rainbow: high = i, low bit-0 = 0 iff (i & 3) == 0.
	ld hl, 256
	ld (PalEntries), hl
	ld hl, PaletteBuf
	xor a
.IdentLoop:
	ld (hl), a
	inc hl
	nextreg NR_PAL_VALUE_9B, a
	push af
	and 3
	jr z, .BlueZero
	ld a, 1
	jr .GotLow
.BlueZero:
	xor a
.GotLow:
	ld (hl), a
	inc hl
	nextreg NR_PAL_VALUE_9B, a
	pop af
	inc a
	jr nz, .IdentLoop
	ret


; Stream pixel data into Layer 2 via MMU3, ImageChunks x 8KB. CF=1 on read fail.
UploadImage:
	ld a, (Layer2Bank16k)
	add a, a
	ld c, a
	ld a, (ImageChunks)
	ld b, a
.Loop:
	ld a, c
	nextreg NR_MMU3_6000, a
	push bc
	ld a, (FileHandle)
	ld hl, $6000
	ld bc, $2000
	rst $08 : db F_READ
	pop bc
	ret c
	inc c
	djnz .Loop
	or a
	ret


; Pick NR $14 (global transparency RGB) such that no L2 pixel matches.
;
; The L2 9-bit comparison is: palette[i].high == NR $14 AND
; palette[i].low_bit0 == NR$4A.bit0. We force NR $4A = 0, then mark
; high bytes of all palette entries with low_bit0 == 0; the first
; unmarked value is safe. If every value is marked we fall back to
; picking any entry and using NR $4A to mask its colour.
SetTransparentColor:
	nextreg NR_FALLBACK_COLOR, 0

	ld hl, (PalEntries)
	ld a, h : or l
	jr z, .NoPalette

	ld hl, RgbBitmap
	ld (hl), 0
	ld de, RgbBitmap+1
	ld bc, 31
	ldir

	ld bc, (PalEntries)
	ld hl, PaletteBuf
.MarkLoop:
	ld a, (hl)                      ; high byte
	inc hl
	bit 0, (hl)                     ; low byte bit 0
	inc hl
	jr nz, .MarkSkip                ; only low_bit0 == 0 can ever match
	push hl
	push bc
	ld b, a
	and $07
	ld c, a                         ; bit position
	ld a, b
	rrca : rrca : rrca
	and $1F                         ; byte index
	ld h, 0
	ld l, a
	ld de, RgbBitmap
	add hl, de
	ld a, 1
	inc c
.Shift:
	dec c
	jr z, .ShiftDone
	add a, a
	jr .Shift
.ShiftDone:
	or (hl)
	ld (hl), a
	pop bc
	pop hl
.MarkSkip:
	dec bc
	ld a, b : or c
	jp nz, .MarkLoop

	ld hl, RgbBitmap
	ld c, 0
.ScanByte:
	ld a, (hl)
	cpl
	or a
	jr nz, .HasUnused
	inc hl
	ld a, c
	add a, 8
	ld c, a
	jr nz, .ScanByte
	; Every RGB is blocked - mask the chosen colour via fallback.
	ld a, (PaletteBuf)
	nextreg NR_FALLBACK_COLOR, a
	jr .Apply
.HasUnused:
	ld b, 0
.BitLoop:
	rra
	jr c, .BitFound
	inc b
	jr .BitLoop
.BitFound:
	ld a, c
	add a, b
.Apply:
	ld (TransparentIdx), a
	nextreg NR_GLOBAL_TRANSPARENCY, a
	ret

.NoPalette:
	xor a
	ld (TransparentIdx), a
	nextreg NR_GLOBAL_TRANSPARENCY, a
	ret


SetL2Mode:
	ld a, (DisplayMode)
	or a         : jr z, .M0
	dec a        : jr z, .M1
	nextreg NR_L2_CTRL, L2MODE_640x256 : ret
.M1:nextreg NR_L2_CTRL, L2MODE_320x256 : ret
.M0:nextreg NR_L2_CTRL, L2MODE_256x192 : ret


; Zero L2 scroll and program the clip window to fullscreen. Defends against
; a caller that left these set up (e.g. file managers carving out a panel).
; X clip units are mode-specific (1px / 2px / 4px), so the values differ.
ResetL2View:
	nextreg NR_L2_SCROLL_X_LO, 0
	nextreg NR_L2_SCROLL_Y,    0
	nextreg NR_L2_SCROLL_X_HI, 0

	nextreg NR_CLIP_INDEX, %00000010
	nextreg NR_L2_CLIP, 0
	ld a, (DisplayMode)
	or a
	jr z, .ClipMode0
	nextreg NR_L2_CLIP, 159
	nextreg NR_L2_CLIP, 0
	nextreg NR_L2_CLIP, 255
	ret
.ClipMode0:
	nextreg NR_L2_CLIP, 255
	nextreg NR_L2_CLIP, 0
	nextreg NR_L2_CLIP, 191
	ret


; Build 256-entry 16-bit byte histogram over the 81920 bytes in L2.
BuildHistogram:
	ld hl, CountTable
	ld (hl), 0
	ld de, CountTable+1
	ld bc, 511
	ldir

	ld a, (Layer2Bank16k)
	add a, a
	ld c, a                         ; first 8KB page
	ld b, 10
.PageLoop:
	ld a, c
	nextreg NR_MMU3_6000, a
	push bc                         ; save (B=pages left, C=cur page)

	ld hl, $6000                    ; src ptr
	ld de, $2000                    ; bytes in this page
.ByteLoop:
	ld a, (hl)
	inc hl
	push hl                         ; save src ptr
	ld h, 0
	ld l, a
	add hl, hl                      ; HL = A * 2
	ld bc, CountTable
	add hl, bc                      ; HL = &CountTable[A]
	inc (hl)                        ; bump low byte
	jr nz, .NoCarry
	inc hl
	inc (hl)                        ; bump high byte (no saturation)
.NoCarry:
	pop hl
	dec de
	ld a, d : or e
	jr nz, .ByteLoop

	pop bc
	inc c
	djnz .PageLoop
	ret


; Pick 640x256x16 over 320x256x256 only if BOTH (a) total count of
; same-nibble bytes ($11..$EE) exceeds the rest excluding $00/$FF, AND
; (b) median of the 14 same-nibble counts exceeds median of the 240
; other counts. (b) prevents one heavily-used same-nibble index in an
; 8bpp image from flipping the verdict. No-op unless NeedProbe == 1.
ProbeNibbles:
	ld a, (NeedProbe)
	or a
	ret z

	xor a
	ld (SameTotalHi), a
	ld (OtherTotalHi), a
	ld hl, 0
	ld (SameTotalLo), hl
	ld (OtherTotalLo), hl

	ld c, 0
.SumLoop:
	ld a, c
	or a   : jr z, .SumNext
	cp $FF : jr z, .SumNext

	; Z = same-nibble (high == low)
	ld b, a
	and $0F
	ld e, a
	ld a, b
	rrca : rrca : rrca : rrca
	and $0F
	cp e
	push af

	; DE = CountTable[C]
	ld h, 0
	ld l, c
	add hl, hl
	push bc
	ld bc, CountTable
	add hl, bc
	pop bc
	ld e, (hl) : inc hl : ld d, (hl)

	pop af
	jr nz, .AddOther

	ld hl, (SameTotalLo)
	add hl, de
	ld (SameTotalLo), hl
	jr nc, .SumNext
	ld hl, SameTotalHi
	inc (hl)
	jr .SumNext

.AddOther:
	ld hl, (OtherTotalLo)
	add hl, de
	ld (OtherTotalLo), hl
	jr nc, .SumNext
	ld hl, OtherTotalHi
	inc (hl)

.SumNext:
	inc c
	jr nz, .SumLoop

	; SameTotal vs OtherTotal (24-bit)
	ld a, (SameTotalHi)
	ld b, a
	ld a, (OtherTotalHi)
	cp b
	jr c, .SameWinsTotal
	jp nz, .Set320Probe
	ld hl, (OtherTotalLo)
	ld de, (SameTotalLo)
	or a : sbc hl, de
	jp nc, .Set320Probe

.SameWinsTotal:
	; Extract the 14 same-nibble counts.
	ld de, SameCounts
	ld c, $11
.ExtractLoop:
	ld h, 0
	ld l, c
	add hl, hl
	push bc
	ld bc, CountTable
	add hl, bc
	pop bc
	ld a, (hl) : ld (de), a : inc hl : inc de
	ld a, (hl) : ld (de), a : inc de
	ld a, c
	add a, $11
	ld c, a
	cp $FF
	jr nz, .ExtractLoop

	; Insertion sort, ascending.
	ld b, 13
	ld ix, SameCounts+2
.SortOuter:
	push bc
	ld e, (ix+0)
	ld d, (ix+1)
	push ix
	pop iy
.SortInner:
	push iy
	pop hl
	ld bc, SameCounts
	or a : sbc hl, bc
	jr z, .SortInsert
	ld c, (iy-2)
	ld b, (iy-1)
	ld h, b : ld l, c
	or a : sbc hl, de
	jr c, .SortInsert
	jr z, .SortInsert
	ld (iy+0), c
	ld (iy+1), b
	dec iy : dec iy
	jr .SortInner
.SortInsert:
	ld (iy+0), e
	ld (iy+1), d
	inc ix : inc ix
	pop bc
	djnz .SortOuter

	ld de, (SameCounts+14)          ; upper median of 14

	xor a
	ld (OtherExceeds), a
	ld c, 0
.MedLoop:
	ld a, c
	or a   : jr z, .MedNext
	cp $FF : jr z, .MedNext
	ld b, a
	and $0F
	ld l, a
	ld a, b
	rrca : rrca : rrca : rrca
	and $0F
	cp l
	jr z, .MedNext                  ; same-nibble: skip

	ld h, 0
	ld l, c
	add hl, hl
	push bc
	push de
	ld bc, CountTable
	add hl, bc
	ld a, (hl) : inc hl : ld h, (hl) : ld l, a
	pop de
	or a : sbc hl, de
	pop bc
	jr z, .MedNext
	jr c, .MedNext
	ld hl, OtherExceeds
	inc (hl)
.MedNext:
	inc c
	jr nz, .MedLoop

	ld a, (OtherExceeds)
	cp 120                          ; >= half of 240 -> median(other) >= median(same)
	jr nc, .Set320Probe

	ld a, 2 : ld (DisplayMode), a
	ret

.Set320Probe:
	ld a, 1 : ld (DisplayMode), a
	ret


; M -> toggle 320 / 640.  Any other key exits.
WaitKey:
.Frame:
	halt

	ld bc, $7FFE                    ; M = row $7FFE bit 2
	in a, (c)
	bit 2, a
	jr z, .ToggleMode

	ld d, $FE
	ld e, 8
.Row:
	ld b, d : ld c, $FE
	in a, (c)
	and $1F : cp $1F
	jr nz, .Pressed
	rlc d
	dec e
	jr nz, .Row
	jr .Frame

.Pressed:
	ret

.ToggleMode:
	ld a, (DisplayMode)
	cp 1 : jr z, .ToMode2
	cp 2 : jr z, .ToMode1
	jr .Frame                       ; mode 0: M does nothing

.ToMode2:
	ld a, 2 : ld (DisplayMode), a
	nextreg NR_L2_CTRL, L2MODE_640x256
	jr .WaitMRelease
.ToMode1:
	ld a, 1 : ld (DisplayMode), a
	nextreg NR_L2_CTRL, L2MODE_320x256
.WaitMRelease:
	halt
	ld bc, $7FFE : in a, (c)
	bit 2, a : jr z, .WaitMRelease
	jr .Frame

;-------------------------------- errors ------------------------------

ErrReadCloseFirst:
	ld a, (FileHandle)
	rst $08 : db F_CLOSE

ErrRead:
	ld hl, MsgRead
	jr ExitErr

ErrBadSize:
	ld hl, MsgBadSize
	jr ExitErr

ErrUsage:
	ld hl, MsgUsage
	jr ExitErr

ErrAlloc:
	ld a, (FileHandle)
	rst $08 : db F_CLOSE
	ld hl, MsgAlloc
	jr ExitErr

ErrOpen:
	ld hl, MsgOpen

ExitErr:
	ld sp, (SavedSP)
	push hl                         ; M_P3DOS in cleanup may clobber HL
	call RestoreRegs
	call FreeL2Buffer
	pop hl
	ei
	xor a                           ; A=0 + HL=msg => custom message
	scf
	ret

;-------------------------------- data --------------------------------

Plus3DosSig: db "PLUS3DOS"

; NextZXOS error-message buffer is ~32 bytes (incl. CRs and bit-7 marker).
MsgUsage:   db ".nxiview <file> by RCL/VV", 'G'+$80
MsgOpen:    db "Cannot open fil", 'e'+$80
MsgRead:    db "Read erro", 'r'+$80
MsgBadSize: db "Unsupported NXI siz", 'e'+$80
MsgAlloc:   db "Out of L2 bank", 's'+$80

CodeEnd: equ $

;-------- uninitialised buffers (excluded from the saved binary) ------

SavedSP:        dw 0
ArgPtr:		dw 0
SavedTurbo:     db 0
OrigL2Bank:     db 0
OrigL2Shadow:   db 0
OrigL2Ctrl:     db 0
OrigDisplayCtrl: db 0
OrigTransparency: db 0
OrigFallback:   db 0
OrigPalCtrl:    db 0
OrigPalIdx:     db 0
OrigScrollX:    db 0
OrigScrollY:    db 0
OrigScrollXHi:  db 0
OrigMmu3:       db 0
OrigClipX1:     db 0
OrigClipX2:     db 0
OrigClipY1:     db 0
OrigClipY2:     db 0
AllocatedCount: db 0
AllocatedBanks: ds 11
FileHandle:     db 0
FStatBuf:       ds 11
Layer2Bank16k:  db 0
PayloadStart:   dw 0
PayloadSizeLo:  dw 0
PayloadSizeHi:  dw 0
DisplayMode:    db 0
PalEntries:     dw 0
ImageChunks:    db 0
NeedProbe:      db 0
SameTotalLo:    dw 0
SameTotalHi:    db 0
OtherTotalLo:   dw 0
OtherTotalHi:   db 0
SameCounts:     ds 28      ; 14 x 16-bit, sorted in ProbeNibbles
OtherExceeds:   db 0
TransparentIdx: db $E3
RgbBitmap:      ds 32      ; 256-bit "blocked RGB" map
HeaderProbe:    ds 8
FilenameBuf:    ds 256
PaletteBuf:     ds 512
CountTable:     ds 512   ; 256 x 16-bit byte histogram

	SAVEBIN "nxiview", $2000, CodeEnd-$2000
