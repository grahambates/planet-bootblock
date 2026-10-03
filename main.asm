; m68k-lint-disable optimization/redundant-zero-displacement

; Based on:
; https://www.dwitter.net/d/35567

; for every vertical pixel:
;     reduce previous state to one of 8 states
;     derive a frequency from that state
;     perturb the state using waves in space + time
;     choose a colour from the state
;     perturb the state again with two interacting waves
;     draw a translucent vertical stroke
; move the drawing position horizontally as time advances

; Strokes are drawn to a chunky buffer as 32 brightness levels, keeping the
; brightest at each pixel, then converted to planar.
;
; One new column is drawn per frame, and the screen scrolls 1px per frame as a
; corkscrew scroller: the bitplane pointers just advance through the buffer,
; so new columns on the right occupy the memory of columns that have scrolled
; off the left on the line above. Each screen width of scrolling only needs
; another DIW_BW bytes.
;
; Slow LFOs vary the time step and pan the wave field vertically, so the image
; keeps changing rather than repeating every ~334 columns.

; Audio buffers are part of the program, so it needs to be in chip RAM
        section main,code_c

        incdir  includes
        include "macros.i"
        include "hw.i"
        include "data/tables.i"

; Display setup: low resolution, interleaved bitplanes, single scrolling playfield.
BPLS = 5                ; Bitplane count
DIW_W = 320             ; Display window width
DIW_H = 254             ; Display window height

; Screen buffer is wider than the display, so we can draw ahead of the visible
; area before the corkscrew wraps it round onto the line above.
SCREEN_W = 384          ; Screen buffer width
SCREEN_H = 256        ; Screen buffer height
PAD_H = 8               ; Hidden rows below the chunky buffer, so runs don't need clipping
FOG = 192               ; Fade towards the brightest level near the top: strength at top/256
DARK = 192              ; Fade towards black near the bottom: strength at bottom/256

PAL_FADE = 512         ; Whole-palette startup fade: 128, 256 or 512 frames
PAL_FADE_SHIFT set 0
        ifeq    PAL_FADE-128
PAL_FADE_SHIFT set 2
        else
        ifeq    PAL_FADE-256
PAL_FADE_SHIFT set 1
        else
        ifne    PAL_FADE-512
        fail    "PAL_FADE must be 128, 256 or 512"
        endc
        endc
        endc

; How far drawing runs ahead of the left edge of the display. Must be enough
; that each 16px strip has been converted to planar before it scrolls into view
; (> 352), but small enough that we don't overwrite visible memory
; (< SCREEN_W-15). A whole number of strips, with LEAD-16 a multiple of 32 so
; the strip being converted is always the other one of the pair.
LEAD = 368
        ifne    (LEAD-16)&31
        fail    "LEAD-16 must be a multiple of 32"
        endc

; LFOs: phase steps per column, Q8 of the 256 entry sine table
OFF_LFO = 11            ; vertical pan
DT_LFO = 23             ; time step
OFF_SHIFT = 5           ; pan = (lfo+SIN_MAX)>>OFF_SHIFT, 0..248
DT_SHIFT = 4            ; time step = TSTEP+(lfo>>DT_SHIFT)

; Bytebeat with echoes. The interrupt fills one buffer of a ring of AUD_BUFS.
; Channel k plays the buffer from k*ECHO_D buffers before at volume 64>>k, so the
; dry signal is on the left (0), echoes on right (1, 2) then left again (3).
; (t*5&t>>7)|(t*3&t>>10)
AUD_PER = 443           ; ~8kHz
AUD_LEN = 128           ; samples per buffer: each buffer starts at a multiple of this
ECHO_D = 20             ; echo delay in buffers (20*128 samples = ~320ms)
AUD_BUFS = 64           ; buffers in the ring: power of 2, at least 3*ECHO_D+2
AUD_RING = AUD_LEN*AUD_BUFS

; The buffer being filled must not be one a channel is playing or has latched
        ifgt    3*ECHO_D+2-AUD_BUFS
        fail    "AUD_BUFS too small for ECHO_D"
        endc
        ifne    AUD_BUFS&(AUD_BUFS-1)
        fail    "AUD_BUFS must be a power of 2"
        endc

; Initial DMA/Interrupt bits:
DMASET = DMAF_SETCLR!DMAF_MASTER!DMAF_RASTER!DMAF_AUD0!DMAF_AUD1!DMAF_AUD2!DMAF_AUD3
INTSET = INTF_SETCLR!INTF_INTEN!INTF_AUD0

;-------------------------------------------------------------------------------

COLORS = 1<<BPLS        ; Number of palette colours
SCREEN_BW = SCREEN_W/16*2 ; byte-width of 1 bitplane line
SCREEN_MOD = SCREEN_BW*(BPLS-1) ; modulo (interleaved)
SCREEN_BPL = SCREEN_BW  ; bitplane offset (interleaved)
SCREEN_ROW = SCREEN_BW+SCREEN_MOD ; byte offset between lines of 1 bitplane
SCREEN_SIZE = SCREEN_BW*SCREEN_H*BPLS ; byte size of screen buffer
DIW_BW = DIW_W/16*2     ; bytes per displayed bitplane line
DIW_MOD = SCREEN_BW-DIW_BW+SCREEN_MOD-2 ; extra fetched word for scrolling
DIW_SIZE = DIW_BW*DIW_H*BPLS ; Display window byte size
DIW_LW = DIW_W ; low res width

; Display windows bounds for centered PAL display:
DIW_XSTRT = $81+(320-DIW_LW)/2
DIW_YSTRT = $2c+(256-DIW_H)/2
DIW_XSTOP = DIW_XSTRT+DIW_LW
DIW_YSTOP = DIW_YSTRT+DIW_H

; Display register values
DIWSTRT = DIW_YSTRT<<8!DIW_XSTRT
DIWSTOP = (DIW_YSTOP&$ff)<<8!(DIW_XSTOP&$ff)
DDFSTRT = (DIW_XSTRT-17)>>1&$fc-8
DDFSTOP = (DIW_XSTRT-17+(DIW_LW>>4-1)<<4)>>1&$fc
BPLCON0 = (BPLS<<12)!(1<<9)

; Screen buffer, at a fixed address at the top of 512K chip RAM, which the OS
; is least likely to be using at boot. The program is unpacked to the 64K below
; it. The screen grows by DIW_BW bytes per screen width scrolled, so reaches
; $80000 after ~3 hours, which is where it will stop working.
; Only the first screen, up to where the first column is drawn, needs clearing:
; everything after that is drawn before it's displayed.
SCREEN_ADDR = $60000
SCREEN_BYTES = SCREEN_SIZE+LEAD/8

SIN_MAX = 63*63         ; peak of generated waveform
LEVELS = COLORS-1      ; brightness levels, 1..LEVELS
STATES = 8             ; wave states, indexed by longword offset
STATE_ROW = STATES*4   ; bytes per YTab/ZTab row
WAVE_LEN = 256         ; samples in the generated waveform (Q8 phase index)
SINE_STEPS = WAVE_LEN/2-2 ; generated samples in each half-wave
STRIP_W = 16           ; one planar word, in chunky pixels
C2P_ROWS = SCREEN_H/STRIP_W ; rows converted per frame
FOG_LEVELS = COLORS*2  ; sums of two pixel levels (plus one spare)
FOG_ROW = FOG_LEVELS*2 ; even/odd pixel lookup banks per screen row
YTAB_H = SCREEN_H+(2*SIN_MAX>>OFF_SHIFT) ; rows needed for max vertical pan
STRIP_SIZE = STRIP_W*(SCREEN_H+PAD_H) ; one 16 column chunky strip

C = dmacon            ; custom register base bias: short displacements via a6

;-------------------------------------------------------------------------------
; d2 = Q8 phase -> sine; a3 = SinTab. Inline so repeated lookup instructions
; can share packed matches without the call/return overhead.
SINLOOK macro
        lsr.w   #8,d2
        add.w   d2,d2
        move.w  (a3,d2.w),d2
        endm

; d2 = Q8 phase -> d2 = cosine, ~ +/-Q7
; a3 = SinTab
; Inlined, as the copies pack smaller than a subroutine and its calls
COSLOOK macro
        add.w   #$4000,d2               ; sine + quarter-cycle = cosine
        SINLOOK
        asr.w   #5,d2
        endm

********************************************************************************
Entrypoint:
********************************************************************************
        ifnd    BOOTBLOCK
; The bootblock saves registers for the return to DOS, so do the same here
        moveq   #0,d0
        movem.l d0-a6,-(sp)
; Executable entry does not inherit the ZX0 decoder's final repeat offset.
        moveq   #-1,d6
        endc

; a5 = Vars and a6 = custom+C for the whole program, including the interrupt
        lea     Vars(pc),a5

        lea     custom+C,a6

; Save system state for Exit
        move.w  intenar-C(a6),-(sp)
        move.w  dmaconr-C(a6),-(sp)
        move.l  $70.w,-(sp)

        lsr.w   d6                     ; $ffff -> $7fff: clear all DMA/interrupt enables
        move.w  d6,dmacon-C(a6)
        move.w  d6,intena-C(a6)

        lea     AudioInt(pc),a0
        move.l  a0,$70.w
; Enable and request the audio interrupt: the first call sets up all the
; channels and fills the first buffer, before DMA starts later.
        move.l  #INTSET<<16!INTF_SETCLR!INTF_AUD0,intena-C(a6) ; intena, intreq

; FogTab[y][v]: sum of two adjacent levels mapped to
; level*S+O. Going down the screen, S and O go linearly from fading towards
; LEVELS by FOG/256 at the top, to fading towards 0 by DARK/256 at the bottom.
; Each row has an even and an odd pixel bank, with ordered dither thresholds
; in the 3 fractional bits, so the pixel loop reads finished colours.
FOG_S0 = (256-FOG)<<10
FOG_S1 = (256-DARK)<<10
FOG_O0 = LEVELS*FOG<<11        ; retain three fractional bits, no rounding bias
FOG_O1 = 0
        lea     FogTab,a0
        move.l  #FOG_S0,d4
        move.l  #FOG_O0,d5
        move.l  #$03070501,d3           ; low bytes cycle through thresholds 1,5,7,3
        move.w  #SCREEN_H-1,d7
.fogY:  moveq   #2-1,d6                 ; two horizontal phases
.fogBank:
        move.l  d5,d2
        clr.b   (a0)+                  ; background stays black
        moveq   #(FOG_LEVELS-1)-1,d1
.fogV:  add.l   d4,d2
        move.l  d2,d0
        swap    d0
        add.b   d3,d0
        lsr.b   #3,d0
        move.b  d0,(a0)+
        dbf     d1,.fogV
        ror.l   #8,d3                   ; next horizontal/vertical dither phase
        dbf     d6,.fogBank
        add.l   #(FOG_S1-FOG_S0)/(SCREEN_H-1),d4
        add.l   #(FOG_O1-FOG_O0)/(SCREEN_H-1),d5
        dbf     d7,.fogY

; Build both sine half-waves together, clearing an equal screen slice per step.
; Use a separate clear when the screen extent does not divide evenly.
SCREEN_CLEAR_LONGS = SCREEN_BYTES/4+1
        lea     SCREEN_ADDR,a0
        ifne    SCREEN_CLEAR_LONGS-(SCREEN_CLEAR_LONGS/SINE_STEPS)*SINE_STEPS
        move.w  #SCREEN_CLEAR_LONGS-1,d0
.clear: clr.l   (a0)+
        dbf     d0,.clear
        endc
        lea     SinTab-Vars(a5),a3
        moveq   #0,d1
        moveq   #WAVE_LEN/2-1,d2        ; initial slope; falls by 2 each step
.loop:
        ifeq    SCREEN_CLEAR_LONGS-(SCREEN_CLEAR_LONGS/SINE_STEPS)*SINE_STEPS
        ifle    SCREEN_CLEAR_LONGS/SINE_STEPS-128
        moveq   #SCREEN_CLEAR_LONGS/SINE_STEPS-1,d0
        else
        move.w  #SCREEN_CLEAR_LONGS/SINE_STEPS-1,d0
        endc
.clearSine:
        clr.l   (a0)+
        dbf     d0,.clearSine
        endc
        subq.l  #2,d2
        move.w  d1,(a3)+
        sub.w   d1,(WAVE_LEN-2*2,a3)
        add.l   d2,d1
        bne.s   .loop
        lea     -SINE_STEPS*2(a3),a3           ; back to SinTab

; Per-state tables, with p = pBase^state (Q14):
;   YTab[y][state]  = cosB<<16 | y*A+$4000 (quarter-cycle for cosA)
;   ZTab[cosA index][state] = level<<16 | z1
;   CStep[state]    = C
; where A = p*KA, B = KB/p, C = TSTEP/p, z1 = (state+3)*256 - p*cosA,
; and level spreads LEVELS..1 over Z1_MIN..Z1_MAX
        move.w  #1<<14,d4               ; p
        moveq   #-STATES*4,d5           ; state*4-STATES*4: counts up to 0
.state:
        move.l  #TSTEP<<14,d0
        divs.w  d4,d0
        move.w  d0,CStep+STATES*4-Vars(a5,d5.w)

; YTab column, accumulating y*A and y*B
        move.w  d4,d0
        muls.w  #KA,d0
        swap    d0
        movea.w d0,a1                   ; A
        move.l  #KB,d3
        divs.w  d4,d3                   ; B
        lea     YTab+STATES*4-Vars(a5),a0
        adda.w  d5,a0
        move.w  #$4000,d6               ; y*A+$4000
        moveq   #0,d1                   ; y*B
        move.w  #YTAB_H-1,d7
.ytab:  move.w  d1,d2
        COSLOOK
        move.w  d2,(a0)+
        move.w  d6,(a0)
        lea     STATE_ROW-2(a0),a0
        add.w   d3,d1
        add.w   a1,d6
        dbf     d7,.ytab

; ZTab column
        lea     ZTab+1+STATES*4-Vars(a5),a0
        adda.w  d5,a0
        move.w  d5,d1
        lsl.w   #6,d1
        add.w   #$300+STATES*4<<6,d1    ; (state+3)*256
        movea.l a3,a4
        move.w  #WAVE_LEN-1,d7
.ztab:  move.w  (a4)+,d0
        muls.w  d4,d0
        swap    d0
        asr.w   #2,d0                   ; (p*sin)>>18 = p*cos Q8
        move.w  d1,d2
        sub.w   d0,d2
        move.w  d2,1(a0)                ; z1
; level = ((Z1_MAX-z1)*(LEVELS-1))/range + 1, rounded
        muls.w  #-(LEVELS-1),d2
        add.l   #Z1_MAX*(LEVELS-1)+(Z1_MAX-Z1_MIN)*3/2,d2
        divu.w  #Z1_MAX-Z1_MIN,d2
        move.b  d2,(a0)
        lea     STATE_ROW(a0),a0
        dbf     d7,.ztab

; p *= pBase
        muls.w  #PBASE,d4
        asl.l   #2,d4
        swap    d4
        addq.w  #4,d5
        bne     .state

; Display setup. No copper: the polled frame update sets bplcon1 and the pointers.
        move.l  #DIWSTRT<<16!DIWSTOP,diwstrt-C(a6)
        move.l  #DDFSTRT<<16!DDFSTOP,ddfstrt-C(a6)
        move.l  #DIW_MOD<<16!DIW_MOD,bpl1mod-C(a6)
        move.w  #BPLCON0,bplcon0-C(a6)

        move.w  #DMASET,dmacon-C(a6)

;-------------------------------------------------------------------------------
; One pixel of chunky -> planar, shifted into d1-d5.
C2P_PIXEL macro
        move.b  (a2)+,d0
; average with pixel below, to smooth out alternating rows
        add.b   STRIP_W-1(a2),d0        ; a2 already advanced one pixel
; fog, which also halves the sum when averaging
        move.b  \1(a0,d0.w),d0         ; pre-dithered even/odd pixel bank
        lsr.b   #1,d0
        addx.w  d1,d1
        lsr.b   #1,d0
        addx.w  d2,d2
        lsr.b   #1,d0
        addx.w  d3,d3
        lsr.b   #1,d0
        addx.w  d4,d4
        lsr.b   #1,d0
        addx.w  d5,d5
        endm

********************************************************************************
; Draw the next column into the chunky strip buffer, and convert 16 rows of
; the previous strip to planar.
;
; Assumes (checked in genTables.js):
;  - z1 is always in 1..$fff, so z1 and z are positive and runs always go down
;  - runs are at most 7 pixels (z < $2000), so can overrun into PAD_H
;
; a3 = SinTab, left by startup and preserved through the loop
; a5 = Vars
;
; Render loop:
; a0 = YTab row for y+pan
; a1 = ZTab
; a2 = run pointer
; a4 = address of pixel (x,y) in chunky strip
; d4 = $1fe0 (ZTab cosA index mask)
; d5 = state*4
; d6 = y
; d7 = t (YTab already includes the cosine quarter-cycle)
********************************************************************************
MainLoop:
; LFOs: pan phase in the high word, time step phase in the low word. A carry
; from the low word just nudges the pan phase.
        move.l  LfoPhase-Vars(a5),d1
        add.l   #OFF_LFO<<16!DT_LFO,LfoPhase-Vars(a5)
; time step
        move.w  d1,d2
        SINLOOK
        asr.w   #DT_SHIFT,d2
        add.w   #TSTEP,d2
        move.w  TPhase-Vars(a5),d7
        add.w   d2,TPhase-Vars(a5)
; vertical pan -> YTab row for the bottom screen pixel
        swap    d1
        move.w  d1,d2
        SINLOOK
        add.w   #SIN_MAX,d2
        ifne    OFF_SHIFT-5
        lsr.w   #OFF_SHIFT,d2
        lsl.w   #5,d2
        else
        and.w   #-STATE_ROW,d2                 ; (pan>>5)*32
        endc
        lea     YTab+(SCREEN_H-1)*STATE_ROW-Vars(a5),a0
        adda.w  d2,a0

; CosC[state] = cos(Column*CStep[state]), modulo 65536.
; d0 = Column is kept through drawing, for the strip and C2P positions.
        move.l  Column-Vars(a5),d0
        moveq   #(STATES-1)*4,d6
.cosC:  move.w  d0,d2
        mulu.w  CStep-Vars(a5,d6.w),d2
        COSLOOK
        move.w  d2,CosC-Vars(a5,d6.w)
        subq.w  #4,d6
        bpl.s   .cosC

; a4 = column in current chunky strip, row 255
        addq.l  #1,Column-Vars(a5)
        moveq   #STRIP_W-1,d1
        and.w   d0,d1
        lea     Strips+(SCREEN_H-1)*STRIP_W-Vars(a5),a4
        btst    #4,d0
        beq.s   .buf0
        lea     STRIP_SIZE(a4),a4 ; switch to alternate strip in pair
.buf0:  add.w   d1,a4

; Clear first padding row, which is averaged with row 255. Runs overrunning
; further down are never read, so can be left.
        clr.b   STRIP_W(a4)

        lea     ZTab-Vars(a5),a1
        move.w  #(WAVE_LEN-1)*STATE_ROW,d4
        moveq   #0,d5
        move.w  #SCREEN_H-1,d6

;-------------------------------------------------------------------------------
.yloop:
; d2 = cosB, d1 = y*A[state]
        move.l  (a0,d5.w),d2
        move.w  d2,d1

; cosA phase = t + y*p/210
; d3 = level:z1 from ZTab[cosA index][state]
        add.w   d7,d1
        lsr.w   #3,d1
        and.w   d4,d1
        add.w   d5,d1
        move.l  (a1,d1.w),d3

; factor = 256 + ((cosB*cosC)>>6)
        swap    d2
        muls.w  CosC-Vars(a5,d5.w),d2
        add.w   #$4000,d2
        lsr.w   #6,d2

; z>>8 = (z1*factor)>>16
        mulu.w  d3,d2
        swap    d2
; Capture the next state before consuming d2 as the run counter.
        move.w  d2,d5
        lsl.w   #2,d5
        and.w   #(STATES-1)*4,d5

; This is the first stroke to reach this pixel, so just overwrite it
        swap    d3
        move.b  d3,(a4)

; Remaining run pixels: max(existing, level)
; run = max(1, z>>10)
        lsr.w   #2,d2
        subq.w  #1,d2
        ble.s   .nextY
        move.l  a4,a2
.drawRun:
        lea     STRIP_W(a2),a2
        cmp.b   (a2),d3
        bls.s   .skip
        move.b  d3,(a2)
.skip:  subq.w  #1,d2
        bne.s   .drawRun

.nextY:
        lea     -STRIP_W(a4),a4
        lea     -STATE_ROW(a0),a0
        dbf     d6,.yloop

;-------------------------------------------------------------------------------
; Chunky -> planar: 16 rows of the previous strip per column, so each strip is
; done by the time the next one is drawn.
; Drawing column c-1: previous strip is ((c-1)>>4)-1, drawn LEAD/16 strips
; along the screen. LEAD-16 is a multiple of 32, so low 5 bits are still c-1.
        add.l   #LEAD-STRIP_W,d0        ; d0 = Column before the increment
        moveq   #STRIP_W-1,d1
        and.w   d0,d1                   ; d1 = chunk of 16 rows
        lea     Strips-Vars(a5),a2
        btst    #4,d0
        bne.s   .c2pBuf0
        lea     STRIP_SIZE(a2),a2 ; next strip
.c2pBuf0:
        move.w  d1,d2
        lsl.w   #8,d2                  ; chunk * C2P_ROWS * STRIP_W
        adda.w  d2,a2                   ; a2 = chunky row

        lea     FogTab,a0
        lsl.w   #3,d2                  ; FOG_ROW / STRIP_W
        adda.w  d2,a0                   ; chunk offset: 0..30720 bytes

; screen offset = strip*2 + chunk*16 lines
; Same sequence as the bitplane pointer update, so it packs as a match
        lsr.l   #4,d0
        add.l   d0,d0
        lea     SCREEN_ADDR,a1
        add.l   d0,a1
        mulu.w  #C2P_ROWS*SCREEN_ROW,d1
        add.l   d1,a1                   ; a1 = screen row
        moveq   #0,d0                   ; pixel is used as a word index

; Convert one chunk; 16 incoming bits replace all old bits in d1-d5.
        moveq   #C2P_ROWS-1,d7
.c2pRow:
        moveq   #STRIP_W/2-1,d6
.c2pPixel:
        C2P_PIXEL 0                     ; even pixel bank
        C2P_PIXEL FOG_LEVELS            ; odd pixel bank
        dbf     d6,.c2pPixel

; Write planar values to screen for row
        movem.w d1-d5,-(sp) ; word per bitplane
        moveq   #BPLS-1,d6
.planes:
        move.w  (sp)+,(a1)
        lea     SCREEN_BPL(a1),a1 ; eventually arrives at 1st bpl of next row
        dbf     d6,.planes

        lea     FOG_ROW(a0),a0          ; next fog row, both pixel phases
        dbf     d7,.c2pRow

        printv  *-MainLoop

;-------------------------------------------------------------------------------
; Column drawn: consume the next vblank before advancing the display.
; Column also supplies the scroll position: drawing and scrolling stay in step.
; With LEAD=368 the previous strip is converted before it becomes visible.
; Drawing may cross the start of vblank, but the pointer update must still
; finish before display fetch begins. Audio interrupts remain enabled.
; Preserve requests raised during drawing. Acknowledge only after detecting
; the event; clearing before polling would throw away that frame's update.
; A stale startup request lets the first update through unsynced, but the
; palette is still all black then.
.wait:  btst    #5,intreqr+1-C(a6)
        beq.s   .wait
        move.w  #INTF_VERTB,intreq-C(a6)

;-------------------------------------------------------------------------------
; Set fine scroll and bitplane pointers. DMA advances the pointers, so they
; need resetting every frame.
        move.l  Column-Vars(a5),d0
        moveq   #$f,d1
        and.w   d0,d1
        mulu.w  #$11,d1                 ; both playfields
        not.b   d1                      ; (15-(S&15))*$11
        move.w  d1,bplcon1-C(a6)
; screen offset = (S>>4)*2
        lsr.l   #4,d0
        add.l   d0,d0
        lea     SCREEN_ADDR,a1
        add.l   d0,a1
        lea     bplpt-C(a6),a0
        rept    BPLS
        move.l  a1,(a0)+
        lea     SCREEN_BPL(a1),a1
        endr

; d0 = 2*(Column>>4), left by the bitplane-pointer calculation. Shifted
; by 2 in total, it gives a byte phase that steps by 8 every 16 columns. Each
; colour adds 8, and while the result is negative it shows the previous
; gradient entry, so a band of shifted colours ripples through the palette.
        ifne    PAL_FADE_SHIFT
        lsl.l   #PAL_FADE_SHIFT,d0
        endc
        lea     Palette(pc),a0
; Prefixing the palette with black lets the lookup fade in without changing
; pixels or scaling RGB channels. Clamp the offset at zero after the fade.
        moveq   #-COLORS*2,d2
        add.l   d0,d2
        bpl.s   .fadeDone
        adda.w  d2,a0
; d0 = 0..62 during the fade (PAL_FADE=512): audio volume scale /64, left
; at its last value afterwards
        move.w  d0,Fade-Vars(a5)
.fadeDone:
        ifne    2-PAL_FADE_SHIFT
        lsl.w   #2-PAL_FADE_SHIFT,d0
        endc
        lea     color00-C(a6),a1
        moveq   #COLORS-1,d7
.pal:   move.w  (a0)+,d1
        tst.b   d0
        bpl.s   .pos
        move.w  -2*2(a0),d1           ; previous colour; a0 already advanced
.pos:
        move.w  d1,(a1)+
        addq.b  #256/COLORS,d0
        dbf     d7,.pal

; The final C2P plane loop leaves d6.w=$ffff, and palette updates preserve it.
; Check exit only after the first column so Exit can derive its masks from d6.
        btst    #CIAB_GAMEPORT0,ciaa
        bne     MainLoop

********************************************************************************
; Back to DOS: everything off, then restore what was saved at the start.
Exit:
        lsr.w   d6 ; $7fff
        move.w  d6,intena-C(a6)
        move.w  d6,dmacon-C(a6)
        move.l  (sp)+,$70.w
        move.w  (sp)+,d0
        addq.w  #1,d6 ; $8000
        or.w    d6,d0
        or.w    (sp)+,d6
        move.w  d0,dmacon-C(a6)
        move.w  d6,intena-C(a6)
        movem.l (sp)+,d0-a6
        rts

********************************************************************************
; Audio interrupt: Paula has started playing the previous buffers, so point
; channel 0 at the next one in the ring and fill it with the next AUD_LEN
; samples. Channels 1-3 get the buffers ECHO_D, 2*ECHO_D and 3*ECHO_D before it,
; at half the volume each time, all scaled by Fade. Also called once before DMA
; starts, so it sets up length and period as well.
********************************************************************************
AudioInt:
        movem.l d0-a6,-(sp)
        move.l  AudioT-Vars(a5),d7
        move.w  d7,d0
        lsl.w   #7,d0
; Channels 3..0: ring offsets t-3*ECHO_D, ..., t, so a0 and d0 finish on the
; newest buffer. Starting from t+ECHO_D is the same when 4 delays fill the ring.
        ifne    (4*ECHO_D)&(AUD_BUFS-1)
        sub.w   #4*ECHO_D*AUD_LEN,d0
        endc
        lea     aud3vol+2-C(a6),a2
        moveq   #64>>3,d1               ; channel 3 starts at 1/8 volume
.ch:
        move.w  Fade-Vars(a5),d3        ; fade in with the palette
        mulu.w  d1,d3
        lsr.w   #6,d3
        add.w   #ECHO_D*AUD_LEN,d0
        and.w   #AUD_RING-1,d0
        lea     AudioBuf-Vars(a5,d0.w),a0
        move.w  d3,-(a2)                ; audxvol (not audxdat: that starts manual mode)
        move.l  #(AUD_LEN/2)<<16!AUD_PER,-(a2) ; audxlen, audxper
        move.l  a0,-(a2)                ; audxlc
        subq.l  #aud1lc-aud0lc-(2+4+4),a2 ; skip remaining channel registers
        add.b   d1,d1
        bpl.s   .ch                     ; until volume 64 is done

; AudioT counts 128-sample buffers: d7 = t>>7, so no
; separate t>>7 calculation or register is needed. d0 is the byte offset
; in the ring, whose low byte is t&128; t*5 and t*3 start there too.
; The mask bytes repeat every 2048 buffers, including across counter wrap.
        move.l  d7,d6
        lsr.l   #3,d6                    ; buffer counter >> 3 = t >> 10
        move.l  d0,d3                   ; t*5 (only the low byte matters, .l packs better)
        move.l  d0,d5                   ; t*3
        moveq   #AUD_LEN-1,d2
.sample:
        move.b  d3,d0
        and.b   d7,d0
        move.b  d5,d4
        and.b   d6,d4
        or.b    d4,d0
        move.b  d0,(a0)+
        addq.b  #5,d3
        addq.b  #3,d5
        dbf     d2,.sample

        addq.l  #1,AudioT-Vars(a5)
        move.w  d1,intreq-C(a6)         ; INTF_AUD0: d1 left at $80 by the channel loop
        movem.l (sp)+,d0-a6
        rte

********************************************************************************
Data:
********************************************************************************

        dcb.w   COLORS,0                 ; black prefix for startup fade
        dc.w    0                         ; previous entry for background ripple
Palette:
        dc.w    0                         ; background

; 0 - Green
; 1 - Blue/Pink
; 2 - Red
; 3 - Blue
; 4 - Purple
; 5 - Purple 2
PALETTE = 3

        ifeq PALETTE-0
; https://gradient-blaster.grahambates.com/?points=000@0,355@11,fe9@24,fff@31&steps=32&blendMode=oklab&ditherMode=blueNoise&target=amigaOcs&ditherAmount=0
Gradient:
	dc.w $000,$000,$000,$011,$111,$111,$122,$133
	dc.w $233,$244,$244,$355,$465,$565,$576,$686
	dc.w $797,$997,$9a7,$ab8,$bb8,$cc8,$dd9,$ee9
	dc.w $fe9,$ffa,$ffb,$ffc,$ffd,$ffd,$fff
        endc

        ifeq PALETTE-1
; https://gradient-blaster.grahambates.com/?points=000@0,345@11,fef@24,fff@31&steps=32&blendMode=oklab&ditherMode=blueNoise&target=amigaOcs&ditherAmount=0
Gradient:
	dc.w $000,$000,$000,$001,$111,$111,$122,$123
	dc.w $223,$234,$234,$345,$346,$456,$567,$678
	dc.w $789,$899,$99a,$aab,$bbc,$ccd,$dde,$fde
	dc.w $fef,$fef,$fff,$fff,$fff,$fff,$fff
        endc

        ifeq PALETTE-2
; https://gradient-blaster.grahambates.com/?points=000@0,533@11,fe9@24,fff@31&steps=32&blendMode=oklab&ditherMode=blueNoise&target=amigaOcs&ditherAmount=0
Gradient:
	dc.w $000,$000,$000,$100,$110,$211,$211,$311
	dc.w $322,$322,$423,$533,$633,$644,$754,$865
	dc.w $975,$a85,$a96,$ba7,$cb7,$dc8,$dc8,$ed9
	dc.w $fe9,$ffa,$ffb,$ffc,$ffd,$ffd,$fff
        endc

        ifeq PALETTE-3
; https://gradient-blaster.grahambates.com/?points=000@0,247@11,ffb@24,fff@31&steps=32&blendMode=oklab&ditherMode=blueNoise&target=amigaOcs&ditherAmount=0
Gradient:
	dc.w $000,$000,$000,$001,$012,$012,$123,$124
	dc.w $125,$135,$236,$247,$258,$358,$468,$678
	dc.w $789,$899,$9aa,$aba,$bca,$cdb,$deb,$eeb
	dc.w $ffb,$ffc,$ffd,$ffd,$ffe,$ffe,$fff
        endc

        ifeq PALETTE-4
; https://gradient-blaster.grahambates.com/?points=000@0,435@11,fe9@24,fff@31&steps=32&blendMode=oklab&ditherMode=blueNoise&target=amigaOcs&ditherAmount=0
Gradient:
	dc.w $000,$000,$000,$001,$101,$112,$212,$213
	dc.w $223,$324,$324,$435,$535,$546,$656,$766
	dc.w $877,$987,$a97,$ba8,$cb8,$db8,$dc9,$ed9
	dc.w $fe9,$ffa,$ffb,$ffc,$ffd,$ffd,$fff
        endc

        ifeq PALETTE-5
; https://gradient-blaster.grahambates.com/?points=000@0,435@10,fe9@24,fff@31&steps=32&blendMode=oklab&ditherMode=blueNoise&target=amigaOcs&ditherAmount=40
Gradient:
	dc.w $000,$000,$000,$101,$111,$112,$212,$213
	dc.w $323,$334,$435,$545,$545,$656,$767,$877
	dc.w $877,$988,$a98,$ba8,$cb8,$dc8,$ed9,$ee9
	dc.w $ff9,$ffa,$ffb,$ffc,$ffd,$ffd,$fff
        endc

********************************************************************************
; Buffers and tables. These are part of the program, and they're all zeros, so
; pack down to almost nothing.
;
; Except FogTab, everything is addressed from Vars in a5, within 32K of the code
; (for lea Vars(pc)) and the start of each table is within 32K of Vars. FogTab
; is generated at startup, so it's kept out of the program entirely.
********************************************************************************


; per cosA index and state: level<<16 | z1
ZTab:   ds.l    WAVE_LEN*STATES

Vars:
Column: ds.l    1               ; columns drawn
TPhase: ds.w    1               ; Q8 time phase
LfoPhase: ds.l  1               ; pan:time step LFO phases
; Per state, indexed by state*4:
CosC:   ds.w    1                    ; cos(Column*CStep[state]) for current column
CStep:  ds.w    STATES*2-1           ; phase step per column for each state
AudioT: ds.l    1               ; 128-sample buffer count
Fade:   ds.w    1               ; audio volume scale /64

; ring of audio buffers: newest is dry, older ones are echoes
AudioBuf: ds.b  AUD_RING

; generated waveform
SinTab: ds.w    WAVE_LEN

; two 16 column chunky strips: one being drawn, one being converted to planar
Strips: ds.b    STRIP_SIZE*2

; per y+pan and state: cosB<<16 | y*A
YTab:   ds.l    YTAB_H*STATES

; Runtime-only dither tables. Keep them outside the boot unpacking area.
        ifd     BOOTBLOCK
FogTab = $48000                 ; 32K ending at the $50000 unpack address
        else
        section fog,bss_c
FogTab: ds.b    SCREEN_H*FOG_ROW
        endc
