; ---------------------------------------------------------------------
; Written by RCL 2024-12-17 and placed in public domain
; ---------------------------------------------------------------------

	device ZXSPECTRUM48

	; This is a regular ZX Spectrum 48K program which, if run from Next or Uno, can detect them and enable 28 Mhz

NEXT_REGISTER_SELECT_243B	EQU $243b
NEXT_REGISTER_ACCESS_253B	EQU $253b

UNO_REGISTER_SELECT_FC3B	EQU $fc3b
UNO_REGISTER_ACCESS_FD3B	EQU $fd3b

	org #8000

	call DetectEnhancedAndEnableTurbo

	; use the color as value, also this measures the border update speed
	ex af, af'
	ld a, 7
	ex af, af'
BorderLoop:
	out (#fe), a
	ex af, af'
	jr BorderLoop	


; --------------------------------------------------------------------------------------------------
; Detects Next and Uno and enables max speed modes for both. Returns A = 0 (regular Speccy), A = 1 (ZX Uno), A = 2 (ZX Spectrum Next)
DetectEnhancedAndEnableTurbo:

	; first try to detect Next
	; register select is $243b, register access is $253b
	; the method of detection is writing a value to "user register" $7f and reading it back to make sure it is it

	ld a, $7f
	ld bc, NEXT_REGISTER_SELECT_243B
	out (c), a

	; test all values just to be sure
	ld d, 255
	ld bc, NEXT_REGISTER_ACCESS_253B
TestUserRegister:
	out (c), d
	nop		; nobody told me that but why not wait just in case?
	in a, (c)
	cp d
	jr nz, NextTestFailed
	dec d
	jr nz, TestUserRegister

	; next test succeeded!
	; enable 28Mhz by writing to reg 7
	ld a, $7
	ld bc, NEXT_REGISTER_SELECT_243B
	out (c), a

	ld a, $3		; 3 is 28Mhz (see https://wiki.specnext.dev/CPU_Speed_Register)
	ld bc, NEXT_REGISTER_ACCESS_253B
	out (c), a

	ld a, 2			; value for Next
	ret

NextTestFailed:
	; try detecting Uno using methods in https://uto.speccy.org/zxunofaq_en.html

	; Note: I do not have an Uno (yet), so I cannot test this atm

	ld a, $ff
	ld bc, UNO_REGISTER_SELECT_FC3B
	out (c), a

	ld bc, UNO_REGISTER_ACCESS_FD3B
	; read core id until 0 and count
	ld d, 0
UnoCoreIdReadLoop:
	in a, (c)
	and a
	jr z, UnoCoreIdRead
	cp 32
	jr c, UnoTestFailed
	cp 128
	jr nc, UnoTestFailed
	inc d
	jr UnoCoreIdReadLoop

UnoCoreIdRead:
	ld a, d
	and a
	; no chars read -> not a Uno
	ret z			; returning 0 means regular ZX Spectrum, which is what it is at this point

	; set max speed (which is 14Mhz according to https://uto.speccy.org/zxunofaq_en.html)
	ld a, 11
	ld bc, UNO_REGISTER_SELECT_FC3B
	out (c), a

	ld bc, UNO_REGISTER_ACCESS_FD3B
	in a,(c)
	and $3f
	or $80

	out (c), a

	ld a, 1
	ret		


UnoTestFailed:
	xor a
	ret


	SAVESNA "EnhancedTurbo.sna", #8000
