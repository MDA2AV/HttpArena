/*
 * void swap_ctx(void **save_sp, void *load_sp)        rdi = save_sp, rsi = load_sp
 *
 * Save the callee-saved registers on the current stack, store the stack pointer, load the other
 * stack pointer, restore its callee-saved registers, and return into whatever it was doing.
 * The System V ABI makes every other register caller-saved, so the compiler has already dealt
 * with them at the call site. (MXCSR and the x87 control word are technically callee-saved too;
 * nothing here changes them, so they are not preserved.)
 *
 * No .note.gnu.property on purpose: an unmarked object leaves the linked binary without the
 * IBT/SHSTK flags, so a shadow stack is never enabled around this hand-built frame.
 */
	.text
	.globl	swap_ctx
	.type	swap_ctx, @function
swap_ctx:
	pushq	%rbp
	pushq	%rbx
	pushq	%r12
	pushq	%r13
	pushq	%r14
	pushq	%r15
	movq	%rsp, (%rdi)
	movq	%rsi, %rsp
	popq	%r15
	popq	%r14
	popq	%r13
	popq	%r12
	popq	%rbx
	popq	%rbp
	ret
	.size	swap_ctx, .-swap_ctx

	.section .note.GNU-stack,"",@progbits
