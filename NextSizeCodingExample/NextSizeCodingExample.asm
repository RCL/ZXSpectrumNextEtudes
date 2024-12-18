; ------------------------------------------------------
; Written by RCL 2024-12-08 and placed in public domain
; ------------------------------------------------------

; This is an example of size-coding for ZX Spectrum Next.
;
; ZX Spectrum Next "dot" commands don't have to be placed in a specific directory or invoked from BASIC,
; NextZXOS browser will perfectly run them from anywhere (see https://gitlab.com/thesmog358/tbblue/-/blob/master/nextzxos/browser.cfg?ref_type=heads#L22)
;
; DOT commands, like .com files of yore, have no header. The below code is runnable as is on the Next!
; This is even better than size coding for the original ZX Spectrum since there you need a BASIC loader!
;
; DOT commands always start at org $2000 (8192 dec) and only the first 8K of the binary is loaded (the rest can be loaded manually using OS calls),
; but for classic 64b / 256b / 512b / 1024b / 4k intros this is more than plenty!
; 
; They are expected to return cleanly to DOS / BASIC, but ... the machine resets really fast!
; Read more technical info here: https://github.com/z88dk/z88dk/blob/master/libsrc/_DEVELOPMENT/EXAMPLES/zxn/dot-command/readme.md
;
; Compile this file and run the resulting .dot binary from the NextZXOS browser.

	device ZXSPECTRUMNEXT


	org $2000

	ld bc, $ffff
	xor a
BorderLoop:
	out (#fe), a
	xor #17
	dec bc
	inc b
	djnz BorderLoop

	xor a		; not having a carry set and A = 0 signifies a clean return
	ret

	SAVEBIN "NextSizeCodingExample_14bytes.dot", $2000, $-$2000	