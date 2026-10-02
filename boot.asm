; Bootblock: unpacks the effect (main.asm, zx0 packed) to chip RAM and runs it.
; The effect never returns, so there's no need to set up a DOS boot.

UNPACK_ADR = $50000             ; 64K below SCREEN_ADDR in main.asm

;-------------------------------------------------------------------------------
        dc.b    "DOS",0         ; BB_ID - Always has to be DOS\0
        dc.l    0               ; BB_CHKSUM - set by mkadf
UnpackAdr:
        dc.l    UNPACK_ADR      ; BB_DOSBLOCK - Rootblock location for DOS disks
;-------------------------------------------------------------------------------
        lea     dos(pc),a1
        jsr     -96(a6) ; FindResdent()
        move.l  d0,a0
        move.l  22(a0),a0 ; DosInit sub
        moveq   #0,d0

        movem.l d0-a6,-(sp)             ; restored by the effect on exit

        lea     PackedData(pc),a0
        move.l  UnpackAdr(pc),a1

; ZX0 decompressor, size-optimised for the bootblock. Based on unzx0_68000.s by
; Emmanuel Marty and Chris Hodges (platon42), with the Elias gamma reader shared
; between its uses rather than inlined.
;
;  unzx0_68000.s - ZX0 decompressor for 68000
;  Copyright (C) 2021 Emmanuel Marty
;  Copyright (C) 2023 Emmanuel Marty, Chris Hodges
;  ZX0 compression (c) 2021 Einar Saukas, https://github.com/einar-saukas/ZX0
;
;  This software is provided 'as-is', without any express or implied
;  warranty.  In no event will the authors be held liable for any damages
;  arising from the use of this software.
;
;  Permission is granted to anyone to use this software for any purpose,
;  including commercial applications, and to alter it and redistribute it
;  freely, subject to the following restrictions:
;
;  1. The origin of this software must not be misrepresented; you must not
;     claim that you wrote the original software. If you use this software
;     in a product, an acknowledgment in the product documentation would be
;     appreciated but is not required.
;  2. Altered source versions must be plainly marked as such, and must not be
;     misrepresented as being the original software.
;  3. This notice may not be removed or altered from any source distribution.
;
;  in:  a0 = start of compressed data
;       a1 = start of decompression buffer
;  trashes: d0-d1/d6

        move.l  a1,-(sp)        ; return address for the rts when done
        moveq   #-128,d1        ; empty bit queue, plus bit to roll into carry
        moveq   #-1,d6          ; rep-offset = 1

.literals:
        moveq   #1,d0
        bsr.s   .elias
; Elias returns the literal count directly; SUBQ/BNE saves two bytes here.
.copy_lits:
        move.b  (a0)+,(a1)+
        subq.w  #1,d0
        bne.s   .copy_lits

        add.b   d1,d1           ; read 'match or rep-match' bit
        bcs.s   .get_offset

; rep-match
        moveq   #1,d0
        bsr.s   .elias
        subq.w  #1,d0
.do_copy_offs:
.copy_match:
        move.b  (a1,d6.l),(a1)+ ; dest + negative match offset
        dbra    d0,.copy_match

        add.b   d1,d1           ; read 'literal or match' bit
        bcc.s   .literals

.get_offset:
        moveq   #-2,d0
        bsr.s   .elias          ; high byte of match offset
        addq.b  #1,d0
        beq.s   .done           ; EOD marker
        move.b  d0,-(sp)
        move.w  (sp)+,d6
        move.b  (a0)+,d6        ; low byte of offset + 1 bit of length
        moveq   #1,d0           ; length 2 if the bit is set
        asr.l   #1,d6
        bcs.s   .do_copy_offs
        add.b   d1,d1
        addx.w  d0,d0
        bsr.s   .elias
        bra.s   .do_copy_offs

; Interlaced Elias gamma: d0 = initial value, returns value
.elias:
        add.b   d1,d1           ; shift bit queue, high bit into carry
        bne.s   .got_bit
        move.b  (a0)+,d1        ; read 8 new bits
        addx.b  d1,d1
.got_bit:
        bcs.s   .done           ; control bit 1: done
        add.b   d1,d1           ; data bit
        addx.w  d0,d0
        bra.s   .elias

.done:  rts                     ; end of Elias value, or start of unpacked code

PackedData:
        incbin  out/a.zx0

dos:
        dc.b    "dos.library",0