    .org 0x0
    .set noat
    .set noreorder
    .set nomacro
    .globl _start
_start:     
            li  $10, 0x100              #10=$4, sets the base address of the array to $10
            li  $11, 0x10f              # end of array

            ori $1,$0,0x114
            ori $2,$0,0x514
            ori $3,$0,0x1919
            ori $4,$0,0x810

            sw   $1,0x100($0)       # [0x100] = 0x114514
            sw   $2,0x104($0)       # [0x104] = 0x1919
            sw   $3,0x108($0)       # [0x108] = 0x810
            sw   $4,0x10c($0)       # [0x10c] = 0x00

_loop:       
            lw  $t0, 0($10)         # sets $t0 to the current element in array

            lw  $t1, 4($10)         # sets $t1 to the next element in array
            #blt $t1, $t0, _swap     unluckily mips don't provide a blt instruction.
	    sub $t4,$t0,$t1
	    bltz $t4,_swap
            nop
	    addi    $10, $10, 4     # advance the array to start at the next location from last time
            beq $10,$11,end
            nop
            j   _loop                # jump back to loop so we can compare next two elements
            nop

_swap:       sw  $t0, 4($10)         # store the greater numbers contents in the higher position in array (swap)
            sw  $t1, 0($10)         # store the lesser numbers contents in the lower position in array (swap)
            li  $10, 0x100              # resets the value of $10 back to zero so we can start from beginning of array
            j   _loop                # jump back to the loop so we can go through and find next swap
            nop

end:
            j end
            nop
