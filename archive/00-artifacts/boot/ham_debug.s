	.file	"herb_runtime_freestanding.c"
	.text
	.p2align 4
	.def	ham_put_i32;	.scl	3;	.type	32;	.endef
	.seh_proc	ham_put_i32
ham_put_i32:
	pushq	%rbx
	.seh_pushreg	%rbx
	.seh_endprologue
	movq	%rdx, %rax
	movl	%r8d, %edx
	movslq	(%rax), %r8
	leal	1(%r8), %r9d
	movl	%r9d, (%rax)
	movb	%dl, (%rcx,%r8)
	movslq	(%rax), %rbx
	leal	1(%rbx), %r9d
	movl	%r9d, (%rax)
	movb	%dh, (%rcx,%rbx)
	movslq	(%rax), %r8
	leal	1(%r8), %r9d
	movl	%r9d, (%rax)
	movl	%edx, %r9d
	sarl	$24, %edx
	sarl	$16, %r9d
	movb	%r9b, (%rcx,%r8)
	movslq	(%rax), %r8
	leal	1(%r8), %r9d
	movl	%r9d, (%rax)
	movb	%dl, (%rcx,%r8)
	popq	%rbx
	ret
	.seh_endproc
	.section .rdata,"dr"
.LC0:
	.ascii "%s::%s\0"
	.text
	.p2align 4
	.def	create_entity;	.scl	3;	.type	32;	.endef
	.seh_proc	create_entity
create_entity:
	pushq	%r15
	.seh_pushreg	%r15
	pushq	%r14
	.seh_pushreg	%r14
	pushq	%r13
	.seh_pushreg	%r13
	pushq	%r12
	.seh_pushreg	%r12
	pushq	%rbp
	.seh_pushreg	%rbp
	pushq	%rdi
	.seh_pushreg	%rdi
	pushq	%rsi
	.seh_pushreg	%rsi
	pushq	%rbx
	.seh_pushreg	%rbx
	subq	$328, %rsp
	.seh_stackalloc	328
	.seh_endprologue
	movslq	352256+g_graph(%rip), %rbp
	leaq	g_graph(%rip), %rsi
	leal	1(%rbp), %eax
	movq	%rbp, %rdi
	movl	$0, 715804(%rsi,%rbp,4)
	movl	%eax, 352256+g_graph(%rip)
	imulq	$344, %rbp, %rax
	movl	%r8d, 567572(%rsi,%rbp,4)
	movl	%ecx, %r12d
	movl	%edx, %r13d
	movl	%ebp, (%rsi,%rax)
	movl	%ecx, 4(%rsi,%rax)
	movl	%edx, 8(%rsi,%rax)
	movl	$0, 336(%rsi,%rax)
	testl	%r8d, %r8d
	js	.L4
	movl	%ebp, %edx
	movl	%r8d, %ecx
	call	container_add
.L4:
	movslq	584728+g_graph(%rip), %rax
	testl	%eax, %eax
	jle	.L3
	xorl	%ebx, %ebx
	leaq	571928+g_graph(%rip), %rdx
	jmp	.L7
	.p2align 4
	.p2align 4,,10
	.p2align 3
.L12:
	addq	$1, %rbx
	cmpq	%rax, %rbx
	je	.L3
.L7:
	cmpl	(%rdx,%rbx,4), %r12d
	jne	.L12
	movl	%r13d, %ecx
	movslq	%ebx, %rbx
	call	str_of
	movq	%rax, 48(%rsp)
	movslq	584472(%rsi,%rbx,4), %rax
	testl	%eax, %eax
	jle	.L3
	leaq	(%rbx,%rbx,2), %r15
	leaq	572184+g_graph(%rip), %rdx
	salq	$6, %r15
	leaq	(%rax,%rax,2), %rax
	leaq	178948(%rbp), %r13
	salq	$4, %rbp
	addq	%rdx, %r15
	leaq	(%r15,%rax,4), %rax
	movq	%rax, 56(%rsp)
	.p2align 4
	.p2align 3
.L8:
	movl	(%r15), %ecx
	addq	$12, %r15
	call	str_of
	movq	48(%rsp), %r9
	movl	$256, %edx
	leaq	.LC0(%rip), %r8
	movq	%rax, 32(%rsp)
	leaq	64(%rsp), %rcx
	call	herb_snprintf
	movslq	423940(%rsi), %rbx
	leaq	64(%rsp), %rcx
	movq	%rbx, %r14
	leal	1(%rbx), %eax
	imulq	$280, %rbx, %rbx
	movl	%eax, 423940(%rsi)
	movl	%r14d, 352260(%rsi,%rbx)
	call	intern
	movl	%eax, 352264(%rsi,%rbx)
	movl	-8(%r15), %eax
	movl	%eax, 352268(%rsi,%rbx)
	movl	-4(%r15), %eax
	movl	$0, 352532(%rsi,%rbx)
	movl	%eax, 352272(%rsi,%rbx)
	movslq	12(%rsi,%r13,4), %rax
	movl	%edi, 352536(%rsi,%rbx)
	leal	1(%rax), %ecx
	addq	%rbp, %rax
	movl	%ecx, 12(%rsi,%r13,4)
	movl	-12(%r15), %ecx
	movl	%r14d, 650268(%rsi,%rax,4)
	movl	%ecx, 584732(%rsi,%rax,4)
	cmpq	56(%rsp), %r15
	jne	.L8
.L3:
	movl	%edi, %eax
	addq	$328, %rsp
	popq	%rbx
	popq	%rsi
	popq	%rdi
	popq	%rbp
	popq	%r12
	popq	%r13
	popq	%r14
	popq	%r15
	ret
	.seh_endproc
	.section .rdata,"dr"
.LC1:
	.ascii "+\0"
.LC2:
	.ascii "-\0"
.LC3:
	.ascii "*\0"
.LC4:
	.ascii ">\0"
.LC5:
	.ascii "<\0"
.LC6:
	.ascii ">=\0"
.LC7:
	.ascii "<=\0"
.LC8:
	.ascii "==\0"
.LC9:
	.ascii "!=\0"
.LC10:
	.ascii "and\0"
.LC11:
	.ascii "or\0"
	.text
	.p2align 4
	.def	ham_init_op_ids.part.0;	.scl	3;	.type	32;	.endef
	.seh_proc	ham_init_op_ids.part.0
ham_init_op_ids.part.0:
	subq	$40, %rsp
	.seh_stackalloc	40
	.seh_endprologue
	leaq	.LC1(%rip), %rcx
	call	intern
	leaq	.LC2(%rip), %rcx
	movl	%eax, ham_id_add(%rip)
	call	intern
	leaq	.LC3(%rip), %rcx
	movl	%eax, ham_id_sub(%rip)
	call	intern
	leaq	.LC4(%rip), %rcx
	movl	%eax, ham_id_mul(%rip)
	call	intern
	leaq	.LC5(%rip), %rcx
	movl	%eax, ham_id_gt(%rip)
	call	intern
	leaq	.LC6(%rip), %rcx
	movl	%eax, ham_id_lt(%rip)
	call	intern
	leaq	.LC7(%rip), %rcx
	movl	%eax, ham_id_gte(%rip)
	call	intern
	leaq	.LC8(%rip), %rcx
	movl	%eax, ham_id_lte(%rip)
	call	intern
	leaq	.LC9(%rip), %rcx
	movl	%eax, ham_id_eq(%rip)
	call	intern
	leaq	.LC10(%rip), %rcx
	movl	%eax, ham_id_neq(%rip)
	call	intern
	leaq	.LC11(%rip), %rcx
	movl	%eax, ham_id_and(%rip)
	call	intern
	movl	$1, ham_op_ids_init(%rip)
	movl	%eax, ham_id_or(%rip)
	addq	$40, %rsp
	ret
	.seh_endproc
	.p2align 4
	.def	ham_expr_compilable;	.scl	3;	.type	32;	.endef
	.seh_proc	ham_expr_compilable
ham_expr_compilable:
	subq	$40, %rsp
	.seh_stackalloc	40
	.seh_endprologue
	leaq	.L20(%rip), %r8
	movq	%rcx, %rdx
.L24:
	testq	%rdx, %rdx
	je	.L17
.L16:
	cmpl	$7, (%rdx)
	ja	.L17
	movl	(%rdx), %eax
	movslq	(%r8,%rax,4), %rax
	addq	%r8, %rax
	jmp	*%rax
	.section .rdata,"dr"
	.align 4
.L20:
	.long	.L25-.L20
	.long	.L17-.L20
	.long	.L17-.L20
	.long	.L25-.L20
	.long	.L25-.L20
	.long	.L22-.L20
	.long	.L21-.L20
	.long	.L19-.L20
	.text
	.p2align 4,,10
	.p2align 3
.L25:
	movl	$1, %eax
.L14:
	addq	$40, %rsp
	ret
	.p2align 4,,10
	.p2align 3
.L22:
	movl	12(%rdx), %r8d
	testl	%r8d, %r8d
	je	.L33
	.p2align 4
	.p2align 3
.L17:
	xorl	%eax, %eax
.L34:
	addq	$40, %rsp
	ret
	.p2align 4,,10
	.p2align 3
.L19:
	movq	8(%rdx), %rdx
	testq	%rdx, %rdx
	jne	.L16
	xorl	%eax, %eax
	jmp	.L34
	.p2align 4,,10
	.p2align 3
.L21:
	movl	ham_op_ids_init(%rip), %eax
	testl	%eax, %eax
	je	.L35
.L23:
	movl	8(%rdx), %eax
	cmpl	%eax, ham_id_mul(%rip)
	je	.L17
	cmpl	%eax, ham_id_or(%rip)
	je	.L17
	movq	16(%rdx), %rcx
	movq	%rdx, 48(%rsp)
	call	ham_expr_compilable
	movq	48(%rsp), %rdx
	leaq	.L20(%rip), %r8
	testl	%eax, %eax
	je	.L17
	movq	24(%rdx), %rdx
	jmp	.L24
	.p2align 4,,10
	.p2align 3
.L33:
	movl	24(%rdx), %ecx
	testl	%ecx, %ecx
	jne	.L17
	movl	8(%rdx), %eax
	notl	%eax
	shrl	$31, %eax
	jmp	.L14
	.p2align 4,,10
	.p2align 3
.L35:
	movq	%rdx, 48(%rsp)
	call	ham_init_op_ids.part.0
	movq	48(%rsp), %rdx
	jmp	.L23
	.seh_endproc
	.p2align 4
	.def	ham_compile_expr;	.scl	3;	.type	32;	.endef
	.seh_proc	ham_compile_expr
ham_compile_expr:
	pushq	%rbx
	.seh_pushreg	%rbx
	subq	$48, %rsp
	.seh_stackalloc	48
	.seh_endprologue
	movq	%rcx, %r10
	movq	%rdx, %rbx
	movq	%r8, %r11
	testq	%rcx, %rcx
	je	.L38
	movl	96(%rsp), %eax
	movslq	(%r8), %rdx
	subl	$10, %eax
	cmpl	%eax, %edx
	jge	.L38
	cmpl	$7, (%rcx)
	ja	.L38
	movl	(%rcx), %eax
	leaq	.L40(%rip), %rcx
	movslq	(%rcx,%rax,4), %rax
	addq	%rcx, %rax
	jmp	*%rax
	.section .rdata,"dr"
	.align 4
.L40:
	.long	.L45-.L40
	.long	.L38-.L40
	.long	.L38-.L40
	.long	.L44-.L40
	.long	.L43-.L40
	.long	.L42-.L40
	.long	.L41-.L40
	.long	.L39-.L40
	.text
	.p2align 4,,10
	.p2align 3
.L39:
	movl	96(%rsp), %eax
	movq	8(%r10), %rcx
	movq	%rbx, %rdx
	movq	%r8, 80(%rsp)
	movl	%eax, 32(%rsp)
	call	ham_compile_expr
	testl	%eax, %eax
	je	.L38
	movq	80(%rsp), %r11
	movslq	(%r11), %rax
	leal	1(%rax), %edx
	movl	%edx, (%r11)
	movb	$47, (%rbx,%rax)
	.p2align 4
	.p2align 3
.L46:
	movl	$1, %eax
.L36:
	addq	$48, %rsp
	popq	%rbx
	ret
	.p2align 4,,10
	.p2align 3
.L41:
	movl	96(%rsp), %eax
	movq	16(%r10), %rcx
	movq	%rbx, %rdx
	movq	%r10, 64(%rsp)
	movq	%r9, 88(%rsp)
	movl	%eax, 32(%rsp)
	movq	%r8, 80(%rsp)
	call	ham_compile_expr
	testl	%eax, %eax
	jne	.L75
	.p2align 4
	.p2align 3
.L38:
	xorl	%eax, %eax
	jmp	.L36
	.p2align 4,,10
	.p2align 3
.L42:
	leal	1(%rdx), %eax
	movl	%eax, (%r8)
	movb	$34, (%rbx,%rdx)
.L74:
	movslq	(%r11), %rax
	movl	8(%r10), %edx
	leal	1(%rax), %ecx
	movl	%ecx, (%r11)
	movb	%dl, (%rbx,%rax)
	movslq	(%r11), %rax
	leal	1(%rax), %ecx
	movl	%ecx, (%r11)
	movb	%dh, (%rbx,%rax)
	jmp	.L46
	.p2align 4,,10
	.p2align 3
.L43:
	movslq	32(%r9), %rcx
	testl	%ecx, %ecx
	jle	.L38
	movl	12(%r10), %r8d
	xorl	%eax, %eax
	jmp	.L50
	.p2align 4
	.p2align 4,,10
	.p2align 3
.L48:
	addq	$1, %rax
	cmpq	%rax, %rcx
	je	.L38
.L50:
	cmpl	(%r9,%rax,4), %r8d
	jne	.L48
	cltq
	movl	16(%r9,%rax,4), %ecx
	testl	%ecx, %ecx
	js	.L38
	leal	1(%rdx), %eax
	movl	%eax, (%r11)
	movb	$33, (%rbx,%rdx)
	movslq	(%r11), %rax
	leal	1(%rax), %edx
	movl	%edx, (%r11)
	movb	%cl, (%rbx,%rax)
	jmp	.L74
	.p2align 4,,10
	.p2align 3
.L44:
	leal	1(%rdx), %eax
	movq	%rbx, %rcx
	movl	%eax, (%r8)
	xorl	%r8d, %r8d
	movb	$32, (%rbx,%rdx)
	movl	8(%r10), %edx
	testl	%edx, %edx
	movq	%r11, %rdx
	setne	%r8b
	call	ham_put_i32
	jmp	.L46
	.p2align 4,,10
	.p2align 3
.L45:
	leal	1(%rdx), %eax
	movq	%rbx, %rcx
	movl	%eax, (%r8)
	movb	$32, (%rbx,%rdx)
	movl	8(%r10), %r8d
	movq	%r11, %rdx
	call	ham_put_i32
	jmp	.L46
	.p2align 4,,10
	.p2align 3
.L75:
	movq	64(%rsp), %r10
	movl	96(%rsp), %eax
	movq	%rbx, %rdx
	movq	88(%rsp), %r9
	movq	80(%rsp), %r8
	movq	24(%r10), %rcx
	movl	%eax, 32(%rsp)
	call	ham_compile_expr
	testl	%eax, %eax
	je	.L38
	movl	ham_op_ids_init(%rip), %eax
	movq	80(%rsp), %r11
	movq	64(%rsp), %r10
	testl	%eax, %eax
	jne	.L51
	call	ham_init_op_ids.part.0
	movq	80(%rsp), %r11
	movq	64(%rsp), %r10
.L51:
	movl	8(%r10), %eax
	cmpl	%eax, ham_id_add(%rip)
	je	.L76
	cmpl	%eax, ham_id_sub(%rip)
	je	.L77
	cmpl	%eax, ham_id_gt(%rip)
	je	.L78
	cmpl	%eax, ham_id_lt(%rip)
	je	.L79
	cmpl	%eax, ham_id_gte(%rip)
	je	.L80
	cmpl	%eax, ham_id_lte(%rip)
	je	.L81
	cmpl	%eax, ham_id_eq(%rip)
	je	.L82
	cmpl	%eax, ham_id_neq(%rip)
	je	.L83
	cmpl	%eax, ham_id_and(%rip)
	jne	.L38
	movslq	(%r11), %rax
	leal	1(%rax), %edx
	movl	%edx, (%r11)
	movb	$45, (%rbx,%rax)
	jmp	.L46
	.p2align 4,,10
	.p2align 3
.L76:
	movslq	(%r11), %rax
	leal	1(%rax), %edx
	movl	%edx, (%r11)
	movb	$36, (%rbx,%rax)
	jmp	.L46
.L77:
	movslq	(%r11), %rax
	leal	1(%rax), %edx
	movl	%edx, (%r11)
	movb	$37, (%rbx,%rax)
	jmp	.L46
.L78:
	movslq	(%r11), %rax
	leal	1(%rax), %edx
	movl	%edx, (%r11)
	movb	$39, (%rbx,%rax)
	jmp	.L46
.L79:
	movslq	(%r11), %rax
	leal	1(%rax), %edx
	movl	%edx, (%r11)
	movb	$40, (%rbx,%rax)
	jmp	.L46
.L80:
	movslq	(%r11), %rax
	leal	1(%rax), %edx
	movl	%edx, (%r11)
	movb	$41, (%rbx,%rax)
	jmp	.L46
.L81:
	movslq	(%r11), %rax
	leal	1(%rax), %edx
	movl	%edx, (%r11)
	movb	$42, (%rbx,%rax)
	jmp	.L46
.L82:
	movslq	(%r11), %rax
	leal	1(%rax), %edx
	movl	%edx, (%r11)
	movb	$43, (%rbx,%rax)
	jmp	.L46
.L83:
	movslq	(%r11), %rax
	leal	1(%rax), %edx
	movl	%edx, (%r11)
	movb	$44, (%rbx,%rax)
	jmp	.L46
	.seh_endproc
	.p2align 4
	.def	br_to_ref;	.scl	3;	.type	32;	.endef
	.seh_proc	br_to_ref
br_to_ref:
	pushq	%rdi
	.seh_pushreg	%rdi
	pushq	%rsi
	.seh_pushreg	%rsi
	pushq	%rbx
	.seh_pushreg	%rbx
	.seh_endprologue
	movq	%rcx, %rax
	movl	$-1, (%rdx)
	movq	%rdx, %r10
	movq	16(%rcx), %rcx
	movq	8(%rax), %rdx
	movl	$-1, (%r8)
	movl	$-1, (%r9)
	cmpq	%rdx, %rcx
	jnb	.L85
	movq	(%rax), %rsi
	leaq	1(%rcx), %r11
	movq	%r11, 16(%rax)
	movzbl	(%rsi,%rcx), %ebx
	testb	%bl, %bl
	jne	.L86
	movq	%r11, %rcx
.L85:
	leaq	2(%rcx), %r8
	cmpq	%r8, %rdx
	jb	.L102
	movq	(%rax), %r9
	movzbl	1(%r9,%rcx), %edx
	movzbl	(%r9,%rcx), %ecx
	movq	%r8, 16(%rax)
	sall	$8, %edx
	orl	%ecx, %edx
	cmpw	$-1, %dx
	je	.L90
	movzwl	%dx, %eax
.L87:
	cmpl	%eax, g_bin_str_count(%rip)
	jle	.L90
	leaq	g_bin_str_ids(%rip), %rdx
	movl	(%rdx,%rax,4), %eax
.L89:
	movl	%eax, (%r10)
.L84:
	popq	%rbx
	popq	%rsi
	popq	%rdi
	ret
	.p2align 4,,10
	.p2align 3
.L86:
	cmpb	$1, %bl
	jne	.L84
	leaq	3(%rcx), %rbx
	cmpq	%rbx, %rdx
	jb	.L92
	movzbl	2(%rsi,%rcx), %r10d
	movzbl	(%rsi,%r11), %r11d
	movq	%rbx, 16(%rax)
	sall	$8, %r10d
	orl	%r11d, %r10d
	cmpw	$-1, %r10w
	je	.L104
	movzwl	%r10w, %r10d
	cmpl	%r10d, g_bin_str_count(%rip)
	leaq	5(%rcx), %r11
	jle	.L103
	leaq	g_bin_str_ids(%rip), %rdi
	movl	(%rdi,%r10,4), %r10d
.L94:
	movl	%r10d, (%r8)
	cmpq	%r11, %rdx
	jb	.L100
	movzbl	4(%rsi,%rcx), %edx
	movzbl	(%rsi,%rbx), %ecx
	movq	%r11, 16(%rax)
	sall	$8, %edx
	orl	%ecx, %edx
	cmpw	$-1, %dx
	je	.L99
	movzwl	%dx, %eax
.L96:
	cmpl	%eax, g_bin_str_count(%rip)
	jle	.L99
	leaq	g_bin_str_ids(%rip), %rdx
	movl	(%rdx,%rax,4), %eax
.L98:
	movl	%eax, (%r9)
	jmp	.L84
	.p2align 4,,10
	.p2align 3
.L102:
	xorl	%eax, %eax
	jmp	.L87
	.p2align 4,,10
	.p2align 3
.L92:
	movl	g_bin_str_count(%rip), %eax
	testl	%eax, %eax
	jle	.L101
	movl	g_bin_str_ids(%rip), %eax
	movl	%eax, (%r8)
.L100:
	xorl	%eax, %eax
	jmp	.L96
	.p2align 4,,10
	.p2align 3
.L90:
	movl	$-1, %eax
	jmp	.L89
.L99:
	movl	$-1, %eax
	jmp	.L98
.L103:
	movl	$-1, %r10d
	jmp	.L94
.L101:
	movl	$-1, (%r8)
	xorl	%eax, %eax
	jmp	.L96
.L104:
	leaq	5(%rcx), %r11
	movl	$-1, %r10d
	jmp	.L94
	.seh_endproc
	.section .rdata,"dr"
.LC12:
	.ascii "expr pool full\0"
	.section	.text.unlikely,"x"
.LCOLDB15:
	.text
.LHOTB15:
	.p2align 4
	.def	br_expr;	.scl	3;	.type	32;	.endef
	.seh_proc	br_expr
br_expr:
	pushq	%rdi
	.seh_pushreg	%rdi
	pushq	%rsi
	.seh_pushreg	%rsi
	pushq	%rbx
	.seh_pushreg	%rbx
	subq	$48, %rsp
	.seh_stackalloc	48
	.seh_endprologue
	movq	16(%rcx), %rax
	movq	%rcx, %rdi
	cmpq	8(%rcx), %rax
	jnb	.L197
	movq	(%rcx), %rdx
	leaq	1(%rax), %rcx
	movq	%rcx, 16(%rdi)
	movzbl	(%rdx,%rax), %esi
	cmpb	$-1, %sil
	je	.L108
	movslq	g_expr_count(%rip), %rbx
	cmpl	$4095, %ebx
	jg	.L198
	leal	1(%rbx), %eax
	salq	$5, %rbx
	movl	$32, %r8d
	xorl	%edx, %edx
	movl	%eax, g_expr_count(%rip)
	leaq	g_expr_pool(%rip), %rax
	addq	%rax, %rbx
	movq	%rbx, %rcx
	call	herb_memset
.L110:
	cmpb	$10, %sil
	ja	.L108
	leaq	.L113(%rip), %rdx
	movslq	(%rdx,%rsi,4), %rax
	addq	%rdx, %rax
	jmp	*%rax
	.section .rdata,"dr"
	.align 4
.L113:
	.long	.L111-.L113
	.long	.L122-.L113
	.long	.L121-.L113
	.long	.L120-.L113
	.long	.L119-.L113
	.long	.L118-.L113
	.long	.L117-.L113
	.long	.L116-.L113
	.long	.L115-.L113
	.long	.L114-.L113
	.long	.L112-.L113
	.text
	.p2align 4,,10
	.p2align 3
.L197:
	movslq	g_expr_count(%rip), %rbx
	cmpl	$4095, %ebx
	jg	.L194
	leal	1(%rbx), %eax
	salq	$5, %rbx
	movl	$32, %r8d
	xorl	%edx, %edx
	movl	%eax, g_expr_count(%rip)
	leaq	g_expr_pool(%rip), %rax
	addq	%rax, %rbx
	movq	%rbx, %rcx
	call	herb_memset
.L111:
	movq	16(%rdi), %rdx
	movl	$0, (%rbx)
	xorl	%r8d, %r8d
	leaq	8(%rdx), %r9
	cmpq	%r9, 8(%rdi)
	jb	.L124
	addq	(%rdi), %rdx
	xorl	%ecx, %ecx
	.p2align 5
	.p2align 4
	.p2align 3
.L125:
	movzbl	(%rdx), %eax
	addq	$1, %rdx
	salq	%cl, %rax
	addl	$8, %ecx
	orq	%rax, %r8
	cmpl	$64, %ecx
	jne	.L125
	movq	%r9, 16(%rdi)
.L124:
	movq	%r8, 8(%rbx)
	jmp	.L105
	.p2align 4,,10
	.p2align 3
.L198:
	leaq	.LC12(%rip), %rdx
	xorl	%ecx, %ecx
	xorl	%ebx, %ebx
	call	herb_error
	jmp	.L110
	.p2align 4,,10
	.p2align 3
.L112:
	movq	16(%rdi), %rdx
	movl	$8, (%rbx)
	leaq	2(%rdx), %rcx
	cmpq	%rcx, 8(%rdi)
	jb	.L186
	movq	(%rdi), %r8
	movzbl	1(%r8,%rdx), %eax
	movzbl	(%r8,%rdx), %edx
	movq	%rcx, 16(%rdi)
	sall	$8, %eax
	orl	%edx, %eax
	cmpw	$-1, %ax
	je	.L167
	movzwl	%ax, %eax
.L164:
	cmpl	%eax, g_bin_str_count(%rip)
	jle	.L167
	leaq	g_bin_str_ids(%rip), %rdx
	movl	(%rdx,%rax,4), %ecx
.L166:
	call	graph_find_container_by_name
	movq	16(%rdi), %rdx
	movl	%eax, 8(%rbx)
	leaq	2(%rdx), %rcx
	cmpq	%rcx, 8(%rdi)
	jb	.L187
	movq	(%rdi), %r8
	movzbl	1(%r8,%rdx), %eax
	movzbl	(%r8,%rdx), %edx
	movq	%rcx, 16(%rdi)
	sall	$8, %eax
	orl	%edx, %eax
	cmpw	$-1, %ax
	je	.L171
.L169:
	movzwl	%ax, %eax
.L168:
	cmpl	%eax, g_bin_str_count(%rip)
	jle	.L171
	leaq	g_bin_str_ids(%rip), %rdx
	movl	(%rdx,%rax,4), %eax
.L170:
	movl	%eax, 12(%rbx)
.L105:
	movq	%rbx, %rax
	addq	$48, %rsp
	popq	%rbx
	popq	%rsi
	popq	%rdi
	ret
	.p2align 4,,10
	.p2align 3
.L114:
	movl	$7, (%rbx)
	movq	%rdi, %rcx
	call	br_expr
	movq	%rax, 8(%rbx)
	jmp	.L105
	.p2align 4,,10
	.p2align 3
.L115:
	movq	16(%rdi), %rdx
	movl	$6, (%rbx)
	leaq	2(%rdx), %rcx
	cmpq	%rcx, 8(%rdi)
	jb	.L185
	movq	(%rdi), %r8
	movzbl	1(%r8,%rdx), %eax
	movzbl	(%r8,%rdx), %edx
	movq	%rcx, 16(%rdi)
	sall	$8, %eax
	orl	%edx, %eax
	cmpw	$-1, %ax
	je	.L163
	movzwl	%ax, %eax
.L160:
	cmpl	%eax, g_bin_str_count(%rip)
	jle	.L163
	leaq	g_bin_str_ids(%rip), %rdx
	movl	(%rdx,%rax,4), %eax
.L162:
	movl	%eax, 8(%rbx)
	movq	%rdi, %rcx
	call	br_expr
	movq	%rdi, %rcx
	movq	%rax, 16(%rbx)
	call	br_expr
	movq	%rax, 24(%rbx)
	jmp	.L105
	.p2align 4,,10
	.p2align 3
.L116:
	movq	.LC14(%rip), %rax
	movq	16(%rdi), %rdx
	movl	$5, (%rbx)
	movl	$1, 24(%rbx)
	movq	%rax, 8(%rbx)
	leaq	2(%rdx), %rcx
	cmpq	%rcx, 8(%rdi)
	jb	.L183
	movq	(%rdi), %r8
	movzbl	1(%r8,%rdx), %eax
	movzbl	(%r8,%rdx), %edx
	movq	%rcx, 16(%rdi)
	sall	$8, %eax
	orl	%edx, %eax
	cmpw	$-1, %ax
	je	.L157
	movzwl	%ax, %eax
.L154:
	cmpl	%eax, g_bin_str_count(%rip)
	jle	.L157
	leaq	g_bin_str_ids(%rip), %rdx
	movl	(%rdx,%rax,4), %r8d
.L156:
	movl	720220+g_graph(%rip), %ecx
	testl	%ecx, %ecx
	jle	.L184
	leaq	g_graph(%rip), %rdx
	xorl	%eax, %eax
	jmp	.L159
	.p2align 5
	.p2align 4,,10
	.p2align 3
.L199:
	addl	$1, %eax
	addq	$20, %rdx
	cmpl	%ecx, %eax
	je	.L184
.L159:
	cmpl	%r8d, 719900(%rdx)
	jne	.L199
.L158:
	movl	%eax, 28(%rbx)
	jmp	.L105
	.p2align 4,,10
	.p2align 3
.L117:
	movq	16(%rdi), %rcx
	movq	8(%rdi), %r8
	movl	$5, (%rbx)
	movq	.LC13(%rip), %rax
	movl	$0, 24(%rbx)
	leaq	2(%rcx), %r9
	movq	%rax, 8(%rbx)
	cmpq	%r9, %r8
	jb	.L146
	movq	(%rdi), %rdx
	movzbl	1(%rdx,%rcx), %eax
	movzbl	(%rdx,%rcx), %r10d
	movq	%r9, 16(%rdi)
	sall	$8, %eax
	orl	%r10d, %eax
	cmpw	$-1, %ax
	je	.L200
	movzwl	%ax, %eax
	cmpl	%eax, g_bin_str_count(%rip)
	leaq	4(%rcx), %r9
	jle	.L182
	leaq	g_bin_str_ids(%rip), %r10
	movl	(%r10,%rax,4), %eax
.L148:
	movl	%eax, 16(%rbx)
	cmpq	%r9, %r8
	jb	.L174
	movzbl	3(%rdx,%rcx), %eax
	movzbl	2(%rdx,%rcx), %edx
	movq	%r9, 16(%rdi)
	sall	$8, %eax
	orl	%edx, %eax
	cmpw	$-1, %ax
	je	.L153
	movzwl	%ax, %eax
.L150:
	cmpl	%eax, g_bin_str_count(%rip)
	jle	.L153
	leaq	g_bin_str_ids(%rip), %rdx
	movl	(%rdx,%rax,4), %eax
.L152:
	movl	%eax, 20(%rbx)
	jmp	.L105
	.p2align 4,,10
	.p2align 3
.L118:
	movq	16(%rdi), %rdx
	movl	$5, (%rbx)
	leaq	2(%rdx), %rcx
	cmpq	%rcx, 8(%rdi)
	jb	.L181
	movq	(%rdi), %r8
	movzbl	1(%r8,%rdx), %eax
	movzbl	(%r8,%rdx), %edx
	movq	%rcx, 16(%rdi)
	sall	$8, %eax
	orl	%edx, %eax
	cmpw	$-1, %ax
	je	.L145
	movzwl	%ax, %eax
.L142:
	cmpl	%eax, g_bin_str_count(%rip)
	jle	.L145
	leaq	g_bin_str_ids(%rip), %rdx
	movl	(%rdx,%rax,4), %ecx
.L144:
	call	graph_find_container_by_name
	movl	$0, 12(%rbx)
	movl	%eax, 8(%rbx)
	movl	$0, 24(%rbx)
	jmp	.L105
	.p2align 4,,10
	.p2align 3
.L119:
	movq	16(%rdi), %rcx
	movq	8(%rdi), %r8
	movl	$4, (%rbx)
	leaq	2(%rcx), %r9
	cmpq	%r9, %r8
	jb	.L134
	movq	(%rdi), %rdx
	movzbl	1(%rdx,%rcx), %eax
	movzbl	(%rdx,%rcx), %r10d
	movq	%r9, 16(%rdi)
	sall	$8, %eax
	orl	%r10d, %eax
	cmpw	$-1, %ax
	je	.L201
	movzwl	%ax, %eax
	cmpl	%eax, g_bin_str_count(%rip)
	leaq	4(%rcx), %r9
	jle	.L180
	leaq	g_bin_str_ids(%rip), %r10
	movl	(%r10,%rax,4), %eax
.L136:
	movl	%eax, 8(%rbx)
	cmpq	%r9, %r8
	jb	.L187
	movzbl	3(%rdx,%rcx), %eax
	movzbl	2(%rdx,%rcx), %edx
	movq	%r9, 16(%rdi)
	sall	$8, %eax
	orl	%edx, %eax
	cmpw	$-1, %ax
	jne	.L169
.L171:
	movl	$-1, %eax
	jmp	.L170
	.p2align 4,,10
	.p2align 3
.L120:
	movl	$3, (%rbx)
	movq	16(%rdi), %rax
	xorl	%edx, %edx
	cmpq	8(%rdi), %rax
	jnb	.L133
	movq	(%rdi), %rdx
	leaq	1(%rax), %rcx
	movq	%rcx, 16(%rdi)
	movzbl	(%rdx,%rax), %edx
.L133:
	movl	%edx, 8(%rbx)
	jmp	.L105
	.p2align 4,,10
	.p2align 3
.L121:
	movq	16(%rdi), %rdx
	movl	$2, (%rbx)
	leaq	2(%rdx), %rcx
	cmpq	%rcx, 8(%rdi)
	jb	.L178
	movq	(%rdi), %r8
	movzbl	1(%r8,%rdx), %eax
	movzbl	(%r8,%rdx), %edx
	movq	%rcx, 16(%rdi)
	sall	$8, %eax
	orl	%edx, %eax
	cmpw	$-1, %ax
	je	.L131
	movzwl	%ax, %eax
.L128:
	cmpl	%eax, g_bin_str_count(%rip)
	jle	.L131
	leaq	g_bin_str_ids(%rip), %rdx
	movl	(%rdx,%rax,4), %eax
.L130:
	movl	%eax, 8(%rbx)
	jmp	.L105
	.p2align 4,,10
	.p2align 3
.L122:
	movq	16(%rdi), %rdx
	movl	$1, (%rbx)
	xorl	%r8d, %r8d
	leaq	8(%rdx), %r9
	cmpq	%r9, 8(%rdi)
	jb	.L126
	addq	(%rdi), %rdx
	xorl	%ecx, %ecx
	.p2align 5
	.p2align 4
	.p2align 3
.L127:
	movzbl	(%rdx), %eax
	addq	$1, %rdx
	salq	%cl, %rax
	addl	$8, %ecx
	orq	%rax, %r8
	cmpl	$64, %ecx
	jne	.L127
	movq	%r9, 16(%rdi)
.L126:
	movq	%r8, 32(%rsp)
	leaq	32(%rsp), %rdx
	leaq	40(%rsp), %rcx
	movl	$8, %r8d
	call	herb_memcpy
	movsd	40(%rsp), %xmm0
	movsd	%xmm0, 8(%rbx)
	jmp	.L105
	.p2align 4,,10
	.p2align 3
.L108:
	xorl	%ebx, %ebx
	jmp	.L105
	.p2align 4,,10
	.p2align 3
.L134:
	movl	g_bin_str_count(%rip), %edx
	testl	%edx, %edx
	jle	.L173
	movl	g_bin_str_ids(%rip), %eax
	movl	%eax, 8(%rbx)
.L187:
	xorl	%eax, %eax
	jmp	.L168
.L182:
	movl	$-1, %eax
	jmp	.L148
.L180:
	movl	$-1, %eax
	jmp	.L136
	.p2align 4,,10
	.p2align 3
.L184:
	movl	$-1, %eax
	jmp	.L158
	.p2align 4,,10
	.p2align 3
.L146:
	movl	g_bin_str_count(%rip), %eax
	testl	%eax, %eax
	jle	.L175
	movl	g_bin_str_ids(%rip), %eax
	movl	%eax, 16(%rbx)
.L174:
	xorl	%eax, %eax
	jmp	.L150
	.p2align 4,,10
	.p2align 3
.L181:
	xorl	%eax, %eax
	jmp	.L142
	.p2align 4,,10
	.p2align 3
.L178:
	xorl	%eax, %eax
	jmp	.L128
	.p2align 4,,10
	.p2align 3
.L183:
	xorl	%eax, %eax
	jmp	.L154
	.p2align 4,,10
	.p2align 3
.L185:
	xorl	%eax, %eax
	jmp	.L160
	.p2align 4,,10
	.p2align 3
.L186:
	xorl	%eax, %eax
	jmp	.L164
.L131:
	movl	$-1, %eax
	jmp	.L130
.L153:
	movl	$-1, %eax
	jmp	.L152
.L167:
	movl	$-1, %ecx
	jmp	.L166
.L157:
	movl	$-1, %r8d
	jmp	.L156
.L163:
	movl	$-1, %eax
	jmp	.L162
.L145:
	movl	$-1, %ecx
	jmp	.L144
.L173:
	movl	$-1, 8(%rbx)
	xorl	%eax, %eax
	jmp	.L168
.L175:
	movl	$-1, 16(%rbx)
	xorl	%eax, %eax
	jmp	.L150
.L201:
	leaq	4(%rcx), %r9
	movl	$-1, %eax
	jmp	.L136
.L200:
	leaq	4(%rcx), %r9
	movl	$-1, %eax
	jmp	.L148
	.seh_endproc
	.section	.text.unlikely,"x"
	.def	br_expr.cold;	.scl	3;	.type	32;	.endef
	.seh_proc	br_expr.cold
	.seh_stackalloc	72
	.seh_savereg	%rbx, 48
	.seh_savereg	%rsi, 56
	.seh_savereg	%rdi, 64
	.seh_endprologue
br_expr.cold:
.L194:
	xorl	%ecx, %ecx
	leaq	.LC12(%rip), %rdx
	call	herb_error
	xorl	%ecx, %ecx
	movl	%ecx, 0
	ud2
	.text
	.section	.text.unlikely,"x"
	.seh_endproc
.LCOLDE15:
	.text
.LHOTE15:
	.section .rdata,"dr"
.LC16:
	.ascii "binary too short\0"
.LC17:
	.ascii "bad magic\0"
.LC18:
	.ascii "unsupported version\0"
.LC20:
	.ascii "channel:%s\0"
.LC23:
	.ascii "unknown binary section\0"
	.text
	.p2align 4
	.def	load_program_binary;	.scl	3;	.type	32;	.endef
	.seh_proc	load_program_binary
load_program_binary:
	pushq	%r15
	.seh_pushreg	%r15
	pushq	%r14
	.seh_pushreg	%r14
	pushq	%r13
	.seh_pushreg	%r13
	pushq	%r12
	.seh_pushreg	%r12
	pushq	%rbp
	.seh_pushreg	%rbp
	pushq	%rdi
	.seh_pushreg	%rdi
	pushq	%rsi
	.seh_pushreg	%rsi
	pushq	%rbx
	.seh_pushreg	%rbx
	subq	$504, %rsp
	.seh_stackalloc	504
	movaps	%xmm6, 448(%rsp)
	.seh_savexmm	%xmm6, 448
	movaps	%xmm7, 464(%rsp)
	.seh_savexmm	%xmm7, 464
	movaps	%xmm8, 480(%rsp)
	.seh_savexmm	%xmm8, 480
	.seh_endprologue
	movq	%rdx, %xmm0
	movq	%rcx, 160(%rsp)
	movq	%rdx, %r8
	movups	%xmm0, 168(%rsp)
	cmpq	$7, %rdx
	jbe	.L749
	cmpb	$72, (%rcx)
	jne	.L205
	cmpb	$69, 1(%rcx)
	jne	.L205
	cmpb	$82, 2(%rcx)
	jne	.L205
	cmpb	$66, 3(%rcx)
	jne	.L205
	movq	$5, 176(%rsp)
	cmpb	$1, 4(%rcx)
	jne	.L750
	movl	$0, g_bin_str_count(%rip)
	movzwl	6(%rcx), %r12d
	movq	$8, 176(%rsp)
	testw	%r12w, %r12w
	je	.L209
	movl	$8, %eax
	xorl	%esi, %esi
	leaq	g_bin_str_ids(%rip), %rbx
	xorl	%edi, %edi
	leaq	192(%rsp), %rbp
	.p2align 4
	.p2align 3
.L215:
	xorl	%r11d, %r11d
	cmpq	%r8, %rax
	jnb	.L210
	movq	160(%rsp), %r10
	leaq	1(%rax), %rdx
	movq	%rdx, 176(%rsp)
	movzbl	(%r10,%rax), %r11d
	testl	%r11d, %r11d
	je	.L210
	leal	-1(%r11), %r9d
	movq	%rbp, %rax
	addq	%rbp, %r9
	jmp	.L214
	.p2align 6
	.p2align 4,,10
	.p2align 3
.L751:
	movq	176(%rsp), %rdx
	addq	$1, %rax
.L214:
	xorl	%ecx, %ecx
	cmpq	%r8, %rdx
	jnb	.L212
	leaq	1(%rdx), %rcx
	movq	%rcx, 176(%rsp)
	movzbl	(%r10,%rdx), %ecx
.L212:
	movb	%cl, (%rax)
	cmpq	%rax, %r9
	jne	.L751
.L210:
	movb	$0, 192(%rsp,%r11)
	leal	1(%rsi), %eax
	movq	%rbp, %rcx
	addl	$1, %edi
	movl	%eax, g_bin_str_count(%rip)
	call	intern
	movl	%eax, (%rbx,%rsi,4)
	cmpw	%r12w, %di
	je	.L209
	movslq	g_bin_str_count(%rip), %rsi
	movq	168(%rsp), %r8
	movq	176(%rsp), %rax
	jmp	.L215
.L209:
	leaq	g_graph(%rip), %r12
	movl	$720568, %r8d
	xorl	%edx, %edx
	movq	%r12, %rcx
	call	herb_memset
	leaq	567572(%r12), %rax
	pcmpeqd	%xmm0, %xmm0
	.p2align 5
	.p2align 4
	.p2align 3
.L216:
	movups	%xmm0, (%rax)
	leaq	571668+g_graph(%rip), %rdi
	addq	$32, %rax
	movups	%xmm0, -16(%rax)
	cmpq	%rax, %rdi
	jne	.L216
	leaq	-219132(%rdi), %rax
	leaq	-147452(%rdi), %rdx
	movl	$-1, 720552+g_graph(%rip)
	.p2align 5
	.p2align 4
	.p2align 3
.L217:
	movl	$-1, (%rax)
	addq	$560, %rax
	movl	$-1, -280(%rax)
	cmpq	%rdx, %rax
	jne	.L217
	leaq	160(%rsp), %rdi
	movq	176(%rsp), %rax
	movq	168(%rsp), %rdx
	movq	%rdi, 104(%rsp)
	.p2align 4
	.p2align 3
.L742:
	cmpq	%rdx, %rax
	jnb	.L219
	movq	160(%rsp), %rcx
	leaq	1(%rax), %r9
	movq	%r9, 176(%rsp)
	movzbl	(%rcx,%rax), %r8d
	cmpb	$-1, %r8b
	je	.L219
	cmpb	$9, %r8b
	ja	.L221
	leaq	.L223(%rip), %rdi
	movslq	(%rdi,%r8,4), %r8
	addq	%rdi, %r8
	jmp	*%r8
	.section .rdata,"dr"
	.align 4
.L223:
	.long	.L221-.L223
	.long	.L231-.L223
	.long	.L230-.L223
	.long	.L229-.L223
	.long	.L228-.L223
	.long	.L227-.L223
	.long	.L226-.L223
	.long	.L225-.L223
	.long	.L224-.L223
	.long	.L222-.L223
	.text
.L222:
	leaq	3(%rax), %r8
	cmpq	%r8, %rdx
	jb	.L598
	movzbl	2(%rcx,%rax), %eax
	movzbl	(%rcx,%r9), %ecx
	movq	%r8, 176(%rsp)
	sall	$8, %eax
	orw	%cx, %ax
	movw	%ax, 94(%rsp)
	je	.L599
	xorl	%ecx, %ecx
	movq	104(%rsp), %r13
	leaq	443248(%r12), %rax
	movq	.LC21(%rip), %xmm8
	movw	%cx, 52(%rsp)
	leaq	.L440(%rip), %r15
	movq	.LC22(%rip), %xmm6
	movq	.LC13(%rip), %xmm7
	movq	%rax, 96(%rsp)
	.p2align 4
	.p2align 3
.L380:
	movslq	567568(%r12), %rax
	movl	$1960, %r8d
	imulq	$1960, %rax, %rsi
	leal	1(%rax), %edx
	movq	%rax, 56(%rsp)
	movl	%edx, 567568(%r12)
	xorl	%edx, %edx
	leaq	442128(%r12,%rsi), %rcx
	call	herb_memset
	leaq	8+g_graph(%rip), %rax
	leaq	(%r12,%rsi), %rdx
	movq	176(%rsp), %r8
	movq	168(%rsp), %rcx
	movq	%xmm8, 442128(%rax,%rsi)
	movq	56(%rsp), %rax
	movl	$-1, 442144(%rdx)
	leaq	2(%r8), %r10
	cmpq	%r10, %rcx
	jb	.L381
	movq	160(%rsp), %r9
	movzbl	1(%r9,%r8), %edx
	movzbl	(%r9,%r8), %r11d
	movq	%r10, 176(%rsp)
	sall	$8, %edx
	orl	%r11d, %edx
	cmpw	$-1, %dx
	je	.L752
	movzwl	%dx, %edx
	cmpl	%edx, g_bin_str_count(%rip)
	leaq	4(%r8), %r11
	jle	.L605
	leaq	g_bin_str_ids(%rip), %rbx
	movl	(%rbx,%rdx,4), %edx
.L383:
	imulq	$1960, %rax, %rbx
	movl	%edx, 442128(%r12,%rbx)
	cmpq	%r11, %rcx
	jb	.L606
	movzbl	3(%r9,%r8), %edx
	movzbl	2(%r9,%r8), %r8d
	movq	%r11, 176(%rsp)
	sall	$8, %edx
	orl	%r8d, %edx
	movswl	%dx, %edx
.L384:
	imulq	$1960, %rax, %r14
	addq	%r12, %r14
	movl	%edx, 442132(%r14)
	cmpq	%rcx, %r11
	jnb	.L385
	movq	160(%rsp), %r8
	leaq	1(%r11), %rdx
	movq	%rdx, 176(%rsp)
	movzbl	(%r8,%r11), %r9d
	movl	%r9d, 444084(%r14)
	cmpq	%rcx, %rdx
	jnb	.L386
	leaq	2(%r11), %rdx
	movq	%rdx, 176(%rsp)
	movzbl	1(%r8,%r11), %r8d
	movl	%r8d, 443240(%r14)
	testl	%r8d, %r8d
	je	.L387
	movq	%rsi, 56(%rsp)
	leaq	(%r12,%rsi), %rbx
	xorl	%edi, %edi
	leaq	g_bin_str_ids(%rip), %rbp
	movq	%rax, 80(%rsp)
	.p2align 4
	.p2align 3
.L433:
	xorl	%edx, %edx
	leaq	442152(%rbx), %rcx
	movl	$136, %r8d
	call	herb_memset
	movq	176(%rsp), %rax
	movq	168(%rsp), %rdx
	movl	$-1, 442280(%rbx)
	movq	%xmm6, 442156(%rbx)
	movq	%xmm6, 442272(%rbx)
	movq	%xmm7, 442236(%rbx)
	cmpq	%rdx, %rax
	jnb	.L388
	movq	160(%rsp), %r8
	leaq	1(%rax), %rcx
	movq	%rcx, 176(%rsp)
	movzbl	(%r8,%rax), %r9d
	cmpb	$2, %r9b
	je	.L389
	ja	.L390
	testb	%r9b, %r9b
	je	.L753
	movl	$1, 442152(%rbx)
	leaq	3(%rax), %r9
	cmpq	%r9, %rdx
	jb	.L627
	movzbl	2(%r8,%rax), %ecx
	movzbl	1(%r8,%rax), %eax
	movq	%r9, 176(%rsp)
	sall	$8, %ecx
	orl	%ecx, %eax
	cmpw	$-1, %ax
	je	.L628
	movzwl	%ax, %eax
	cmpl	g_bin_str_count(%rip), %eax
	movq	%r9, %rcx
	jge	.L629
.L818:
	movl	0(%rbp,%rax,4), %eax
.L420:
	movl	%eax, 442156(%rbx)
	cmpq	%rdx, %rcx
	jnb	.L421
	leaq	1(%rcx), %rax
	xorl	%r9d, %r9d
	movq	%rax, 176(%rsp)
	cmpb	$1, (%r8,%rcx)
	sete	%r9b
	movl	%r9d, 442232(%rbx)
	cmpq	%rdx, %rax
	jnb	.L422
	leaq	2(%rcx), %r9
	movq	%r9, 176(%rsp)
	movzbl	1(%r8,%rcx), %eax
	movl	%eax, 442228(%rbx)
	testl	%eax, %eax
	je	.L393
	xorl	%esi, %esi
	jmp	.L427
	.p2align 4,,10
	.p2align 3
.L754:
	movq	160(%rsp), %rdx
	movzbl	1(%rdx,%r9), %eax
	movzbl	(%rdx,%r9), %edx
	movq	%rcx, 176(%rsp)
	sall	$8, %eax
	orl	%edx, %eax
	cmpw	$-1, %ax
	je	.L426
	movzwl	%ax, %eax
	cmpl	g_bin_str_count(%rip), %eax
	jge	.L426
.L755:
	movl	0(%rbp,%rax,4), %ecx
.L425:
	call	graph_find_container_by_name
	movl	%eax, 442164(%rbx,%rsi,4)
	addq	$1, %rsi
	cmpl	%esi, 442228(%rbx)
	jle	.L393
	movq	176(%rsp), %r9
	movq	168(%rsp), %rdx
.L427:
	leaq	2(%r9), %rcx
	cmpq	%rcx, %rdx
	jnb	.L754
	xorl	%eax, %eax
	cmpl	g_bin_str_count(%rip), %eax
	jl	.L755
.L426:
	movl	$-1, %ecx
	jmp	.L425
.L224:
	leaq	3(%rax), %r8
	cmpq	%r8, %rdx
	jb	.L603
	movzbl	2(%rcx,%rax), %eax
	movzbl	(%rcx,%r9), %ecx
	sall	$8, %eax
	orl	%eax, %ecx
	movq	%r8, %rax
	movswl	%cx, %ecx
.L378:
	movl	%ecx, 720552(%r12)
	jmp	.L742
.L225:
	leaq	3(%rax), %r8
	cmpq	%r8, %rdx
	jb	.L598
	movzbl	2(%rcx,%rax), %eax
	movzbl	(%rcx,%r9), %ecx
	movq	%r8, 176(%rsp)
	sall	$8, %eax
	orw	%cx, %ax
	movl	%eax, %ebp
	je	.L599
	movq	.LC19(%rip), %xmm6
	xorl	%esi, %esi
	jmp	.L377
	.p2align 4,,10
	.p2align 3
.L757:
	movq	160(%rsp), %r10
	movzbl	1(%r10,%r8), %eax
	movzbl	(%r10,%r8), %ecx
	movq	%r9, 176(%rsp)
	sall	$8, %eax
	orl	%ecx, %eax
	cmpw	$-1, %ax
	je	.L756
	movzwl	%ax, %eax
	cmpl	%eax, g_bin_str_count(%rip)
	leaq	4(%r8), %r11
	jle	.L600
	leaq	g_bin_str_ids(%rip), %rcx
	movl	(%rcx,%rax,4), %eax
.L363:
	leaq	(%rbx,%rbx,4), %rcx
	movl	%eax, 719900(%r12,%rcx,4)
	cmpq	%r11, %rdx
	jb	.L525
	movzbl	3(%r10,%r8), %eax
	movzbl	(%r10,%r9), %edx
	movq	%r11, 176(%rsp)
	sall	$8, %eax
	orl	%edx, %eax
	cmpw	$-1, %ax
	je	.L368
	movzwl	%ax, %eax
	cmpl	%eax, g_bin_str_count(%rip)
	jle	.L368
.L758:
	leaq	g_bin_str_ids(%rip), %rcx
	movl	(%rcx,%rax,4), %ecx
.L367:
	call	graph_find_entity_by_name
	movl	%eax, %edx
	leaq	(%rbx,%rbx,4), %rax
	movl	%edx, 719904(%r12,%rax,4)
	movq	176(%rsp), %rdx
	leaq	2(%rdx), %rcx
	cmpq	%rcx, 168(%rsp)
	jb	.L601
	movq	160(%rsp), %r8
	movzbl	1(%r8,%rdx), %eax
	movzbl	(%r8,%rdx), %edx
	movq	%rcx, 176(%rsp)
	sall	$8, %eax
	orl	%edx, %eax
	cmpw	$-1, %ax
	je	.L372
	movzwl	%ax, %eax
	cmpl	%eax, g_bin_str_count(%rip)
	jle	.L372
.L822:
	leaq	g_bin_str_ids(%rip), %rcx
	movl	(%rcx,%rax,4), %ecx
.L371:
	call	graph_find_entity_by_name
	movl	%eax, %edx
	leaq	(%rbx,%rbx,4), %rax
	movl	%edx, 719908(%r12,%rax,4)
	movq	176(%rsp), %rdx
	leaq	2(%rdx), %rcx
	cmpq	%rcx, 168(%rsp)
	jb	.L602
	movq	160(%rsp), %r8
	movzbl	1(%r8,%rdx), %eax
	movzbl	(%r8,%rdx), %edx
	movq	%rcx, 176(%rsp)
	sall	$8, %eax
	orl	%edx, %eax
	cmpw	$-1, %ax
	je	.L376
	movzwl	%ax, %eax
	cmpl	%eax, g_bin_str_count(%rip)
	jle	.L376
.L823:
	leaq	g_bin_str_ids(%rip), %rcx
	movl	(%rcx,%rax,4), %eax
.L375:
	leaq	(%rbx,%rbx,4), %rdx
	addl	$1, %esi
	leaq	(%r12,%rdx,4), %rbx
	movl	719900(%rbx), %ecx
	movl	%eax, 719912(%rbx)
	call	str_of
	leaq	.LC20(%rip), %r8
	movl	$256, %edx
	leaq	192(%rsp), %rcx
	movq	%rax, %r9
	call	herb_snprintf
	movslq	423940(%r12), %r15
	leaq	192(%rsp), %rcx
	movq	%r15, %r13
	leal	1(%r15), %eax
	imulq	$280, %r15, %r15
	movl	%eax, 423940(%r12)
	movl	%r13d, 352260(%r12,%r15)
	call	intern
	movq	176(%rsp), %r8
	movl	$0, 352268(%r12,%r15)
	movl	%eax, 352264(%r12,%r15)
	movl	719912(%rbx), %eax
	movq	168(%rsp), %rdx
	movl	%eax, 352272(%r12,%r15)
	leaq	4+g_graph(%rip), %rax
	movq	%xmm6, 352528(%rax,%r15)
	movl	%r13d, 719916(%rbx)
	cmpw	%bp, %si
	je	.L599
.L377:
	movslq	720220(%r12), %rbx
	leaq	2(%r8), %r9
	leal	1(%rbx), %eax
	movl	%eax, 720220(%r12)
	cmpq	%r9, %rdx
	jnb	.L757
	movl	g_bin_str_count(%rip), %r15d
	leaq	(%rbx,%rbx,4), %rax
	testl	%r15d, %r15d
	jle	.L526
	movl	g_bin_str_ids(%rip), %edx
	movl	%edx, 719900(%r12,%rax,4)
.L525:
	xorl	%eax, %eax
.L834:
	cmpl	%eax, g_bin_str_count(%rip)
	jg	.L758
.L368:
	movl	$-1, %ecx
	jmp	.L367
.L226:
	leaq	3(%rax), %r8
	cmpq	%r8, %rdx
	jb	.L598
	movzbl	2(%rcx,%rax), %eax
	movzbl	(%rcx,%r9), %ecx
	movq	%r8, 176(%rsp)
	sall	$8, %eax
	orw	%cx, %ax
	je	.L599
	movq	112(%rsp), %r14
	movq	120(%rsp), %r15
	movw	%ax, 56(%rsp)
	xorl	%ebp, %ebp
	movabsq	$-4294967296, %rdi
	movq	%r8, %rax
	.p2align 4
	.p2align 3
.L360:
	leaq	2(%rax), %r9
	cmpq	%r9, %rdx
	jb	.L324
.L820:
	movq	160(%rsp), %r10
	movzbl	1(%r10,%rax), %ecx
	movzbl	(%r10,%rax), %r8d
	movq	%r9, 176(%rsp)
	sall	$8, %ecx
	orl	%r8d, %ecx
	cmpw	$-1, %cx
	je	.L325
	movzwl	%cx, %r11d
	cmpl	g_bin_str_count(%rip), %r11d
	jge	.L325
	leaq	g_bin_str_ids(%rip), %r8
	leaq	4(%rax), %rcx
	movl	(%r8,%r11,4), %ebx
	cmpq	%rcx, %rdx
	jb	.L759
.L327:
	movzbl	3(%r10,%rax), %eax
	movzbl	(%r10,%r9), %r8d
	movq	%rcx, 176(%rsp)
	sall	$8, %eax
	orl	%r8d, %eax
	cmpw	$-1, %ax
	je	.L587
	movl	g_bin_str_count(%rip), %r8d
	movzwl	%ax, %eax
.L328:
	cmpl	%r8d, %eax
	jge	.L587
	leaq	g_bin_str_ids(%rip), %r8
.L326:
	movl	(%r8,%rax,4), %esi
.L329:
	cmpq	%rdx, %rcx
	jnb	.L330
.L517:
	movq	160(%rsp), %r9
	leaq	1(%rcx), %rax
	movq	%rax, 176(%rsp)
	movzbl	(%r9,%rcx), %r8d
	testb	%r8b, %r8b
	jne	.L331
	movq	%rax, %rcx
.L330:
	leaq	2(%rcx), %r8
	cmpq	%r8, %rdx
	jb	.L743
	movq	160(%rsp), %rdx
	movzbl	1(%rdx,%rcx), %eax
	movzbl	(%rdx,%rcx), %edx
	movq	%r8, 176(%rsp)
	sall	$8, %eax
	orl	%edx, %eax
	cmpw	$-1, %ax
	je	.L335
	movzwl	%ax, %eax
.L332:
	cmpl	%eax, g_bin_str_count(%rip)
	jle	.L335
	leaq	g_bin_str_ids(%rip), %r8
	movl	(%r8,%rax,4), %ecx
	testl	%ecx, %ecx
	jns	.L760
.L335:
	movl	$-1, %r8d
.L334:
	movl	%ebx, %edx
	movl	%esi, %ecx
	call	create_entity
	movq	176(%rsp), %rcx
	movq	168(%rsp), %rdx
	movl	%eax, %r10d
	cmpq	%rdx, %rcx
	jnb	.L343
	movq	160(%rsp), %r8
	leaq	1(%rcx), %rax
	movq	%rax, 176(%rsp)
	movzbl	(%r8,%rcx), %r13d
	testb	%r13b, %r13b
	je	.L344
	movw	%bp, 52(%rsp)
	leaq	g_bin_str_ids(%rip), %rbx
	xorl	%ebp, %ebp
	movl	%r10d, %esi
	.p2align 4
	.p2align 3
.L359:
	leaq	2(%rax), %r8
	cmpq	%r8, %rdx
	jb	.L591
	movq	160(%rsp), %r10
	movzbl	1(%r10,%rax), %ecx
	movzbl	(%r10,%rax), %eax
	movq	%r8, 176(%rsp)
	sall	$8, %ecx
	orl	%eax, %ecx
	cmpw	$-1, %cx
	je	.L592
	movzwl	%cx, %ecx
	cmpl	%ecx, g_bin_str_count(%rip)
	movq	%r8, %rax
	jle	.L593
.L807:
	movl	(%rbx,%rcx,4), %r10d
.L346:
	cmpq	%rdx, %rax
	jnb	.L347
	movq	160(%rsp), %r9
	leaq	1(%rax), %r8
	movq	%r8, 176(%rsp)
	leaq	(%r9,%rax), %r11
	movzbl	(%r11), %ecx
	testb	%cl, %cl
	jne	.L348
	movq	%r8, %rax
.L347:
	leaq	8(%rax), %r11
	xorl	%r8d, %r8d
	cmpq	%r11, %rdx
	jb	.L349
	addq	160(%rsp), %rax
	xorl	%ecx, %ecx
	.p2align 5
	.p2align 4
	.p2align 3
.L350:
	movzbl	(%rax), %edx
	addq	$1, %rax
	salq	%cl, %rdx
	addl	$8, %ecx
	orq	%rdx, %r8
	cmpl	$64, %ecx
	jne	.L350
	movq	%r11, 176(%rsp)
.L349:
	andq	%rdi, %r14
	movq	%r8, 136(%rsp)
	movq	%r8, %r15
	orq	$1, %r14
	movq	%r14, 128(%rsp)
.L744:
	movl	%r10d, %edx
	leaq	128(%rsp), %r8
	movl	%esi, %ecx
	call	entity_set_prop
	movq	176(%rsp), %rax
	movq	168(%rsp), %rdx
.L351:
	addl	$1, %ebp
	cmpb	%r13b, %bpl
	jne	.L359
	movzwl	52(%rsp), %ebp
.L344:
	addl	$1, %ebp
	cmpw	56(%rsp), %bp
	jne	.L360
	movq	%r14, 112(%rsp)
	movq	%r15, 120(%rsp)
	jmp	.L742
.L227:
	leaq	3(%rax), %r8
	cmpq	%r8, %rdx
	jb	.L598
	movzbl	2(%rcx,%rax), %eax
	movzbl	(%rcx,%r9), %r9d
	movq	%r8, 176(%rsp)
	sall	$8, %eax
	orw	%r9w, %ax
	movl	%eax, %r15d
	je	.L599
	movslq	720352(%r12), %rbp
	movl	g_bin_str_count(%rip), %r13d
	movq	%r8, %rax
	xorl	%esi, %esi
	leaq	g_bin_str_ids(%rip), %r11
	leaq	720224+g_graph(%rip), %rdi
	movl	%ebp, 52(%rsp)
	jmp	.L323
	.p2align 4,,10
	.p2align 3
.L763:
	movzbl	1(%rcx,%rax), %r10d
	movzbl	(%rcx,%rax), %ebx
	movq	%r8, 176(%rsp)
	sall	$8, %r10d
	orl	%ebx, %r10d
	cmpw	$-1, %r10w
	je	.L761
	movzwl	%r10w, %r10d
	leaq	4(%rax), %rbx
	cmpl	%r10d, %r13d
	jle	.L309
.L522:
	movl	(%r11,%r10,4), %r10d
	leaq	(%r9,%r9,2), %rax
	movq	%r11, %r14
	movl	%r10d, 720356(%r12,%rax,4)
	cmpq	%rbx, %rdx
	jb	.L310
.L311:
	movzbl	1(%rcx,%r8), %r10d
	movzbl	(%rcx,%r8), %eax
	movq	%rbx, 176(%rsp)
	sall	$8, %r10d
	orl	%eax, %r10d
	cmpw	$-1, %r10w
	je	.L313
	movzwl	%r10w, %r10d
	leaq	4(%r8), %rax
	cmpl	%r10d, %r13d
	jle	.L315
	movl	(%r11,%r10,4), %r10d
	leaq	(%r9,%r9,2), %r8
	movq	%r11, %r14
	movl	$-1, 720360(%r12,%r8,4)
	testl	%r10d, %r10d
	jns	.L520
.L724:
	cmpq	%rax, %rdx
	jb	.L762
.L515:
	movzbl	1(%rcx,%rbx), %r8d
	movzbl	(%rcx,%rbx), %r10d
	movq	%rax, 176(%rsp)
	sall	$8, %r8d
	orl	%r10d, %r8d
	cmpw	$-1, %r8w
	je	.L581
	movzwl	%r8w, %r8d
.L322:
	cmpl	%r8d, %r13d
	jle	.L581
	movq	%r11, %r14
.L514:
	movl	(%r14,%r8,4), %r8d
.L316:
	leaq	(%r9,%r9,2), %r9
	addl	$1, %esi
	movl	%r8d, 720364(%r12,%r9,4)
	cmpw	%r15w, %si
	je	.L742
.L323:
	movslq	720548(%r12), %r9
	leal	1(%r9), %r8d
	movl	%r8d, 720548(%r12)
	leaq	2(%rax), %r8
	cmpq	%r8, %rdx
	jnb	.L763
	movq	%r8, %rbx
	xorl	%r10d, %r10d
	movq	%rax, %r8
	testl	%r13d, %r13d
	jg	.L522
	leaq	(%r9,%r9,2), %r8
	movl	$-1, 720356(%r12,%r8,4)
.L521:
	leaq	(%r9,%r9,2), %r8
	movl	$-1, 720360(%r12,%r8,4)
	movl	$-1, %r8d
	jmp	.L316
.L228:
	leaq	3(%rax), %r8
	cmpq	%r8, %rdx
	jb	.L598
	movzbl	2(%rcx,%rax), %eax
	movzbl	(%rcx,%r9), %r9d
	movq	%r8, 176(%rsp)
	sall	$8, %eax
	orw	%r9w, %ax
	je	.L599
	subl	$1, %eax
	movslq	720352(%r12), %r9
	movl	g_bin_str_count(%rip), %esi
	leaq	g_bin_str_ids(%rip), %rbx
	movzwl	%ax, %eax
	movq	%r9, %r11
	leal	1(%r9), %r10d
	leaq	720224(%r12,%r9,8), %r9
	leal	2(%r11,%rax), %edi
	movq	%r8, %rax
	jmp	.L306
	.p2align 4,,10
	.p2align 3
.L298:
	movzbl	1(%rcx,%rax), %r8d
	movzbl	(%rcx,%rax), %r11d
	movq	%rbp, 176(%rsp)
	sall	$8, %r8d
	orl	%r11d, %r8d
	cmpw	$-1, %r8w
	je	.L764
	movzwl	%r8w, %r8d
	leaq	4(%rax), %r11
	cmpl	%r8d, %esi
	jle	.L302
	movl	(%rbx,%r8,4), %r8d
	movl	%r8d, (%r9)
	cmpq	%r11, %rdx
	jb	.L765
.L304:
	movzbl	3(%rcx,%rax), %r8d
	movzbl	(%rcx,%rbp), %eax
	movq	%r11, 176(%rsp)
	sall	$8, %r8d
	orl	%eax, %r8d
	cmpw	$-1, %r8w
	je	.L575
	movzwl	%r8w, %r8d
	movq	%r11, %rax
.L305:
	cmpl	%r8d, %esi
	jle	.L766
.L303:
	movl	(%rbx,%r8,4), %r8d
.L300:
	addl	$1, %r10d
	movl	%r8d, 4(%r9)
	addq	$8, %r9
	cmpl	%r10d, %edi
	je	.L742
.L306:
	leaq	2(%rax), %rbp
	movl	%r10d, 720352(%r12)
	cmpq	%rbp, %rdx
	jnb	.L298
	testl	%esi, %esi
	jle	.L767
	movl	(%rbx), %r8d
	movl	%r8d, (%r9)
	xorl	%r8d, %r8d
	jmp	.L303
.L229:
	leaq	3(%rax), %r8
	cmpq	%r8, %rdx
	jb	.L598
	movzbl	2(%rcx,%rax), %eax
	movzbl	(%rcx,%r9), %ecx
	xorl	%r15d, %r15d
	movq	%r8, 176(%rsp)
	sall	$8, %eax
	orw	%cx, %ax
	movl	%eax, %ebx
	je	.L599
	.p2align 4
	.p2align 3
.L256:
	movslq	442120(%r12), %rsi
	xorl	%edx, %edx
	movl	$284, %r8d
	imulq	$284, %rsi, %r13
	leal	1(%rsi), %eax
	movl	%eax, 442120(%r12)
	leaq	423944(%r12,%r13), %rcx
	call	herb_memset
	movq	176(%rsp), %rdx
	movq	168(%rsp), %rcx
	leaq	2(%rdx), %r10
	cmpq	%r10, %rcx
	jb	.L257
	movq	160(%rsp), %r9
	movzbl	1(%r9,%rdx), %eax
	movzbl	(%r9,%rdx), %r8d
	movq	%r10, 176(%rsp)
	sall	$8, %eax
	orl	%r8d, %eax
	cmpw	$-1, %ax
	je	.L768
	movzwl	%ax, %eax
	cmpl	%eax, g_bin_str_count(%rip)
	leaq	4(%rdx), %r8
	jle	.L561
	leaq	g_bin_str_ids(%rip), %r11
	movl	(%r11,%rax,4), %eax
.L259:
	imulq	$284, %rsi, %r11
	movl	%eax, 423944(%r12,%r11)
	cmpq	%r8, %rcx
	jb	.L562
	movzbl	3(%r9,%rdx), %eax
	movzbl	2(%r9,%rdx), %edx
	movq	%r8, 176(%rsp)
	sall	$8, %eax
	orl	%edx, %eax
	cmpw	$-1, %ax
	je	.L564
	movzwl	%ax, %eax
.L260:
	cmpl	%eax, g_bin_str_count(%rip)
	jle	.L564
.L781:
	leaq	g_bin_str_ids(%rip), %r11
	movl	(%r11,%rax,4), %edx
.L261:
	imulq	$284, %rsi, %rax
	addq	%r12, %rax
	movl	%edx, 424084(%rax)
	cmpq	%rcx, %r8
	jnb	.L769
	movq	160(%rsp), %r9
	leaq	1(%r8), %rdx
	movq	%rdx, 176(%rsp)
	movzbl	(%r9,%r8), %r11d
	movl	%r11d, 424088(%rax)
	cmpq	%rcx, %rdx
	jnb	.L770
	leaq	2(%r8), %rdx
	movq	%rdx, 176(%rsp)
	movzbl	1(%r9,%r8), %r8d
	movq	%r8, %r10
	testl	%r11d, %r11d
	je	.L267
	movl	%r8d, 424156(%rax)
	testb	%r8b, %r8b
	je	.L268
	imulq	$71, %rsi, %rax
	movl	g_bin_str_count(%rip), %ebp
	leaq	424092(%r12,%r13), %r8
	leaq	g_bin_str_ids(%rip), %rdi
	addq	%r10, %rax
	leaq	424092(%r12,%rax,4), %r11
.L274:
	leaq	2(%rdx), %r10
	cmpq	%r10, %rcx
	jnb	.L273
	jmp	.L565
	.p2align 4,,10
	.p2align 3
.L771:
	movq	%r14, %r10
	xorl	%eax, %eax
	cmpq	%r14, %rcx
	jb	.L272
.L273:
	movzbl	1(%r9,%rdx), %eax
	movzbl	(%r9,%rdx), %edx
	movq	%r10, 176(%rsp)
	sall	$8, %eax
	orl	%edx, %eax
	cmpw	$-1, %ax
	je	.L566
	movzwl	%ax, %eax
	movq	%r10, %rdx
	cmpl	%eax, %ebp
	jle	.L270
.L788:
	leaq	2(%rdx), %r14
.L272:
	movl	(%rdi,%rax,4), %eax
	addq	$4, %r8
	movl	%eax, -4(%r8)
	cmpq	%r11, %r8
	jne	.L771
.L271:
	movq	160(%rsp), %r9
	cmpq	%rcx, %rdx
	jnb	.L263
.L513:
	leaq	1(%rdx), %r8
	movq	%r8, 176(%rsp)
	movzbl	(%r9,%rdx), %r10d
	imulq	$284, %rsi, %rdx
	movq	%r10, %rax
	addq	%r12, %rdx
	movl	424088(%rdx), %r11d
	testl	%r11d, %r11d
	je	.L285
	movl	%r10d, 424224(%rdx)
	testb	%r10b, %r10b
	je	.L284
	imulq	$71, %rsi, %rsi
	movl	g_bin_str_count(%rip), %r10d
	leaq	424160(%r12,%r13), %rdx
	addq	%rsi, %rax
	leaq	g_bin_str_ids(%rip), %rsi
	leaq	424160(%r12,%rax,4), %r11
	jmp	.L291
	.p2align 4,,10
	.p2align 3
.L772:
	movzbl	1(%r9,%r8), %eax
	movzbl	(%r9,%r8), %r8d
	movq	%rdi, 176(%rsp)
	sall	$8, %eax
	orl	%r8d, %eax
	cmpw	$-1, %ax
	je	.L290
	movzwl	%ax, %eax
	cmpl	%eax, %r10d
	jle	.L290
.L773:
	movl	(%rsi,%rax,4), %eax
	addq	$4, %rdx
	movl	%eax, -4(%rdx)
	cmpq	%r11, %rdx
	je	.L284
.L774:
	movq	176(%rsp), %r8
.L291:
	leaq	2(%r8), %rdi
	cmpq	%rdi, %rcx
	jnb	.L772
	xorl	%eax, %eax
	cmpl	%eax, %r10d
	jg	.L773
.L290:
	movl	$-1, %eax
	addq	$4, %rdx
	movl	%eax, -4(%rdx)
	cmpq	%r11, %rdx
	jne	.L774
	.p2align 4
	.p2align 3
.L284:
	addl	$1, %r15d
	cmpw	%bx, %r15w
	jne	.L256
.L747:
	movq	176(%rsp), %rax
	movq	168(%rsp), %rdx
	jmp	.L742
.L230:
	leaq	3(%rax), %r8
	cmpq	%r8, %rdx
	jb	.L598
	movzbl	2(%rcx,%rax), %eax
	movzbl	(%rcx,%r9), %r9d
	movq	%r8, 176(%rsp)
	sall	$8, %eax
	orw	%r9w, %ax
	je	.L599
	leal	-1(%rax), %ebp
	movl	g_bin_str_count(%rip), %edi
	movslq	423940(%r12), %r9
	movq	%r8, %rax
	movzwl	%bp, %ebp
	movq	.LC19(%rip), %r14
	leaq	g_bin_str_ids(%rip), %rsi
	movq	%r9, %rbx
	imulq	$280, %r9, %r9
	leal	1(%rbx), %r10d
	addl	%r10d, %ebp
	leaq	352260(%r12,%r9), %r9
	jmp	.L254
	.p2align 4,,10
	.p2align 3
.L776:
	movzbl	1(%rcx,%rax), %r8d
	movzbl	(%rcx,%rax), %eax
	movq	%r11, 176(%rsp)
	sall	$8, %r8d
	orl	%eax, %r8d
	cmpw	$-1, %r8w
	je	.L554
	movzwl	%r8w, %r8d
	movq	%r11, %rax
	cmpl	%r8d, %edi
	jle	.L247
.L777:
	movl	(%rsi,%r8,4), %r8d
	movl	%r8d, 4(%r9)
	cmpq	%rdx, %rax
	jnb	.L775
.L248:
	leaq	1(%rax), %r11
	movq	%r11, 176(%rsp)
	cmpb	$0, (%rcx,%rax)
	setne	%al
	movzbl	%al, %eax
.L251:
	movl	%eax, 8(%r9)
	leaq	2(%r11), %rax
	cmpq	%rax, %rdx
	jb	.L557
.L250:
	movzbl	1(%rcx,%r11), %r8d
	movzbl	(%rcx,%r11), %r11d
	movq	%rax, 176(%rsp)
	sall	$8, %r8d
	orl	%r11d, %r8d
	cmpw	$-1, %r8w
	je	.L559
	movzwl	%r8w, %r8d
	cmpl	%r8d, %edi
	jle	.L559
.L249:
	movl	(%rsi,%r8,4), %r8d
.L253:
	movl	%r8d, 12(%r9)
	addq	$280, %r9
	movq	%r14, -8(%r9)
	cmpl	%ebp, %r10d
	je	.L742
	addl	$1, %r10d
.L254:
	movl	%ebx, %r8d
	leaq	2(%rax), %r11
	movl	%r10d, 423940(%r12)
	movl	%r10d, %ebx
	movl	%r8d, (%r9)
	cmpq	%r11, %rdx
	jnb	.L776
	xorl	%r8d, %r8d
	cmpl	%r8d, %edi
	jg	.L777
.L247:
	movl	$-1, 4(%r9)
	cmpq	%rdx, %rax
	jb	.L248
	movq	%rax, %r11
	xorl	%eax, %eax
	jmp	.L251
.L231:
	leaq	3(%rax), %r8
	cmpq	%r8, %rdx
	jb	.L598
	movzbl	2(%rcx,%rax), %r9d
	movzbl	1(%rcx,%rax), %eax
	movq	%r8, 176(%rsp)
	sall	$8, %r9d
	orw	%r9w, %ax
	je	.L599
	subl	$1, %eax
	movslq	571924(%r12), %r10
	movl	g_bin_str_count(%rip), %edi
	leaq	g_bin_str_ids(%rip), %rsi
	movzwl	%ax, %eax
	leaq	1(%r10), %rbx
	leaq	(%rax,%rbx), %r11
	movq	%r8, %rax
	jmp	.L245
	.p2align 4,,10
	.p2align 3
.L779:
	movzbl	1(%rcx,%rax), %r8d
	movzbl	(%rcx,%rax), %eax
	movq	%r9, 176(%rsp)
	sall	$8, %r8d
	orl	%r8d, %eax
	cmpw	$-1, %ax
	je	.L541
	movzwl	%ax, %eax
	cmpl	%eax, %edi
	jle	.L541
.L780:
	movl	(%rsi,%rax,4), %r8d
.L234:
	leal	1(%r10), %eax
	movl	%eax, 571924(%r12)
	leaq	571668+g_graph(%rip), %rax
	movl	%r8d, (%rax,%r10,4)
	movq	%r9, %rax
	cmpq	%rdx, %r9
	jnb	.L235
	addq	$1, %rax
	movq	%rax, 176(%rsp)
	movzbl	(%rcx,%r9), %ebp
	testb	%bpl, %bpl
	jne	.L778
.L235:
	movq	%rbx, %r10
	cmpq	%rbx, %r11
	je	.L742
	addq	$1, %rbx
.L245:
	leaq	2(%rax), %r9
	cmpq	%r9, %rdx
	jnb	.L779
	movq	%rax, %r9
	xorl	%eax, %eax
	cmpl	%eax, %edi
	jg	.L780
.L541:
	movl	$-1, %r8d
	jmp	.L234
.L599:
	movq	%r8, %rax
	jmp	.L742
	.p2align 4,,10
	.p2align 3
.L257:
	movl	g_bin_str_count(%rip), %eax
	testl	%eax, %eax
	jle	.L518
	movl	g_bin_str_ids(%rip), %eax
	movl	%eax, 423944(%r12,%r13)
.L519:
	xorl	%eax, %eax
	cmpl	%eax, g_bin_str_count(%rip)
	movq	%rdx, %r8
	jg	.L781
.L564:
	movl	$-1, %edx
	jmp	.L261
	.p2align 4,,10
	.p2align 3
.L769:
	movl	$0, 424088(%rax)
	movl	$0, 424012(%rax)
.L263:
	imulq	$284, %rsi, %rax
	addq	%r12, %rax
	movl	424088(%rax), %edi
	testl	%edi, %edi
	jne	.L266
	movl	$0, 424080(%rax)
	addl	$1, %r15d
	cmpw	%bx, %r15w
	jne	.L256
	jmp	.L747
	.p2align 4,,10
	.p2align 3
.L598:
	movq	%r9, %rax
	jmp	.L742
	.p2align 4,,10
	.p2align 3
.L285:
	movl	%r10d, 424080(%rdx)
	testb	%r10b, %r10b
	je	.L284
	imulq	$71, %rsi, %rsi
	leaq	424016(%r12,%r13), %rbp
	leaq	g_bin_str_ids(%rip), %rdi
	addq	%rsi, %rax
	leaq	424016(%r12,%rax,4), %rsi
	jmp	.L297
	.p2align 4,,10
	.p2align 3
.L782:
	movq	160(%rsp), %rcx
	movzbl	1(%rcx,%r8), %eax
	movzbl	(%rcx,%r8), %ecx
	movq	%rdx, 176(%rsp)
	sall	$8, %eax
	orl	%ecx, %eax
	cmpw	$-1, %ax
	je	.L295
	movzwl	%ax, %eax
	cmpl	%eax, g_bin_str_count(%rip)
	jle	.L295
.L783:
	movl	(%rdi,%rax,4), %ecx
.L294:
	call	graph_find_container_by_name
	testl	%eax, %eax
	js	.L296
	movl	%eax, 0(%rbp)
.L296:
	addq	$4, %rbp
	cmpq	%rsi, %rbp
	je	.L284
	movq	176(%rsp), %r8
.L297:
	leaq	2(%r8), %rdx
	cmpq	%rdx, 168(%rsp)
	jnb	.L782
	xorl	%eax, %eax
	cmpl	%eax, g_bin_str_count(%rip)
	jg	.L783
.L295:
	movl	$-1, %ecx
	jmp	.L294
.L267:
	movl	%r8d, 424012(%rax)
	testb	%r8b, %r8b
	je	.L567
	imulq	$71, %rsi, %rax
	movw	%bx, 52(%rsp)
	leaq	g_bin_str_ids(%rip), %rbp
	movl	%r8d, %r14d
	leaq	423948(%r12,%r13), %rbx
	addq	%r8, %rax
	leaq	423948(%r12,%rax,4), %rdi
	jmp	.L281
	.p2align 4,,10
	.p2align 3
.L785:
	movq	160(%rsp), %rcx
	movzbl	1(%rcx,%rdx), %eax
	movzbl	(%rcx,%rdx), %edx
	movq	%r9, 176(%rsp)
	sall	$8, %eax
	orl	%edx, %eax
	cmpw	$-1, %ax
	je	.L279
	movzwl	%ax, %eax
	cmpl	%eax, g_bin_str_count(%rip)
	jle	.L279
.L786:
	movl	0(%rbp,%rax,4), %ecx
.L278:
	call	graph_find_container_by_name
	testl	%eax, %eax
	js	.L280
	movl	%eax, (%rbx)
.L280:
	addq	$4, %rbx
	movq	176(%rsp), %rdx
	movq	168(%rsp), %rcx
	cmpq	%rdi, %rbx
	je	.L784
.L281:
	leaq	2(%rdx), %r9
	cmpq	%r9, %rcx
	jnb	.L785
	xorl	%eax, %eax
	cmpl	%eax, g_bin_str_count(%rip)
	jg	.L786
.L279:
	movl	$-1, %ecx
	jmp	.L278
	.p2align 4,,10
	.p2align 3
.L784:
	movzwl	52(%rsp), %ebx
	movl	%r14d, %r8d
.L275:
	imulq	$284, %rsi, %rax
	movl	%r8d, 424012(%r12,%rax)
	jmp	.L271
.L770:
	testl	%r11d, %r11d
	je	.L787
	movl	$0, 424156(%rax)
.L266:
	imulq	$284, %rsi, %rsi
	addl	$1, %r15d
	movl	$0, 424224(%r12,%rsi)
	cmpw	%bx, %r15w
	jne	.L256
	jmp	.L747
	.p2align 4,,10
	.p2align 3
.L565:
	xorl	%eax, %eax
	cmpl	%eax, %ebp
	jg	.L788
.L270:
	movl	$-1, (%r8)
	addq	$4, %r8
	cmpq	%r8, %r11
	jne	.L274
	jmp	.L271
.L221:
	leaq	.LC23(%rip), %rdx
	movl	$1, %ecx
	call	herb_error
.L219:
	xorl	%eax, %eax
.L202:
	movaps	448(%rsp), %xmm6
	movaps	464(%rsp), %xmm7
	movaps	480(%rsp), %xmm8
	addq	$504, %rsp
	popq	%rbx
	popq	%rsi
	popq	%rdi
	popq	%rbp
	popq	%r12
	popq	%r13
	popq	%r14
	popq	%r15
	ret
.L787:
	movl	$0, 424012(%rax)
	jmp	.L263
	.p2align 4,,10
	.p2align 3
.L389:
	movl	$2, 442152(%rbx)
	leaq	3(%rax), %r9
	cmpq	%r9, %rdx
	jb	.L631
	movzbl	2(%r8,%rax), %eax
	movzbl	(%r8,%rcx), %edx
	movq	%r9, 176(%rsp)
	sall	$8, %eax
	orl	%edx, %eax
	cmpw	$-1, %ax
	je	.L431
	movzwl	%ax, %eax
	cmpl	g_bin_str_count(%rip), %eax
	jge	.L431
.L819:
	movl	0(%rbp,%rax,4), %ecx
.L430:
	call	graph_find_container_by_name
	xorl	%edx, %edx
	movl	%eax, 442248(%rbx)
	movq	176(%rsp), %rax
	cmpq	168(%rsp), %rax
	jnb	.L432
	leaq	1(%rax), %rdx
	movq	%rdx, 176(%rsp)
	movq	160(%rsp), %rdx
	movzbl	(%rdx,%rax), %edx
.L432:
	movl	%edx, 442244(%rbx)
	.p2align 4
	.p2align 3
.L393:
	addl	$1, %edi
	addq	$136, %rbx
	cmpl	%edi, 443240(%r14)
	jg	.L433
	movq	56(%rsp), %rsi
	movq	80(%rsp), %rax
	movq	176(%rsp), %rdx
	movq	168(%rsp), %rcx
.L387:
	cmpq	%rcx, %rdx
	jnb	.L434
	imulq	$1960, %rax, %rbp
	leaq	1(%rdx), %rcx
	movq	%rcx, 176(%rsp)
	movq	160(%rsp), %rcx
	movzbl	(%rcx,%rdx), %edx
	addq	%r12, %rbp
	movl	%edx, 444080(%rbp)
	testl	%edx, %edx
	je	.L436
	addq	96(%rsp), %rsi
	xorl	%ebx, %ebx
	leaq	g_bin_str_ids(%rip), %rdi
	.p2align 4
	.p2align 3
.L511:
	movl	$104, %r8d
	xorl	%edx, %edx
	movq	%rsi, %rcx
	call	herb_memset
	movq	176(%rsp), %rax
	movq	168(%rsp), %r11
	movq	%xmm6, 12(%rsi)
	movq	%xmm6, 56(%rsi)
	movq	%xmm6, 92(%rsi)
	cmpq	%r11, %rax
	jnb	.L437
	movq	160(%rsp), %rdx
	leaq	1(%rax), %r8
	movq	%r8, 176(%rsp)
	cmpb	$5, (%rdx,%rax)
	ja	.L438
	movzbl	(%rdx,%rax), %ecx
	movslq	(%r15,%rcx,4), %rcx
	addq	%r15, %rcx
	jmp	*%rcx
	.section .rdata,"dr"
	.align 4
.L440:
	.long	.L633-.L440
	.long	.L444-.L440
	.long	.L443-.L440
	.long	.L442-.L440
	.long	.L441-.L440
	.long	.L439-.L440
	.text
	.p2align 4,,10
	.p2align 3
.L633:
	movq	%r8, %rax
.L437:
	leaq	2(%rax), %r10
	movl	$0, (%rsi)
	cmpq	%r10, %r11
	jb	.L789
	movq	160(%rsp), %rcx
	movzbl	1(%rcx,%rax), %edx
	movzbl	(%rcx,%rax), %ecx
	movq	%r10, 176(%rsp)
	sall	$8, %edx
	orl	%ecx, %edx
	cmpw	$-1, %dx
	je	.L790
	movzwl	%dx, %edx
	cmpl	%edx, g_bin_str_count(%rip)
	leaq	4(%rax), %r9
	jle	.L791
.L446:
	movl	(%rdi,%rdx,4), %r8d
.L450:
	movl	442120(%r12), %ecx
	testl	%ecx, %ecx
	jle	.L637
.L447:
	movq	%r12, %rdx
	xorl	%eax, %eax
	jmp	.L452
	.p2align 5
	.p2align 4,,10
	.p2align 3
.L792:
	addl	$1, %eax
	addq	$284, %rdx
	cmpl	%ecx, %eax
	je	.L637
.L452:
	cmpl	%r8d, 423944(%rdx)
	jne	.L792
	movl	%eax, 4(%rsi)
	cmpq	%r9, %r11
	jb	.L448
.L453:
	movq	160(%rsp), %rdx
	movzbl	1(%rdx,%r10), %eax
	movzbl	(%rdx,%r10), %edx
	movq	%r9, 176(%rsp)
	sall	$8, %eax
	orl	%edx, %eax
	cmpw	$-1, %ax
	je	.L457
	movzwl	%ax, %eax
.L454:
	cmpl	%eax, g_bin_str_count(%rip)
	jle	.L457
	movl	(%rdi,%rax,4), %eax
.L456:
	movl	%eax, 8(%rsi)
	leaq	12(%rsi), %rdx
	leaq	20(%rsi), %r9
	movq	%r13, %rcx
	leaq	16(%rsi), %r8
	call	br_to_ref
.L438:
	addl	$1, %ebx
	addq	$104, %rsi
	cmpl	%ebx, 444080(%rbp)
	jg	.L511
.L436:
	addw	$1, 52(%rsp)
	movzwl	52(%rsp), %eax
	cmpw	94(%rsp), %ax
	jne	.L380
	jmp	.L747
	.p2align 4,,10
	.p2align 3
.L439:
	leaq	3(%rax), %r8
	movl	$5, (%rsi)
	cmpq	%r8, %r11
	jb	.L652
	movzbl	2(%rdx,%rax), %ecx
	movzbl	1(%rdx,%rax), %eax
	movq	%r8, 176(%rsp)
	sall	$8, %ecx
	orl	%ecx, %eax
	cmpw	$-1, %ax
	je	.L510
	movzwl	%ax, %eax
	cmpl	%eax, g_bin_str_count(%rip)
	jle	.L510
.L826:
	leaq	g_bin_str_ids(%rip), %rcx
	movl	(%rcx,%rax,4), %eax
.L509:
	movl	%eax, 88(%rsi)
	leaq	92(%rsi), %rdx
	leaq	100(%rsi), %r9
	movq	%r13, %rcx
	leaq	96(%rsi), %r8
	call	br_to_ref
	jmp	.L438
	.p2align 4,,10
	.p2align 3
.L441:
	leaq	3(%rax), %r9
	movl	$4, (%rsi)
	cmpq	%r9, %r11
	jb	.L793
	movzbl	2(%rdx,%rax), %ecx
	movzbl	(%rdx,%r8), %r8d
	movq	%r9, 176(%rsp)
	sall	$8, %ecx
	orl	%ecx, %r8d
	cmpw	$-1, %r8w
	je	.L794
	movzwl	%r8w, %r8d
	addq	$5, %rax
	cmpl	%r8d, g_bin_str_count(%rip)
	jle	.L795
.L493:
	leaq	g_bin_str_ids(%rip), %rcx
	movl	(%rcx,%r8,4), %r14d
.L497:
	movl	720548(%r12), %r10d
	testl	%r10d, %r10d
	jle	.L650
.L494:
	movq	%r12, %r8
	xorl	%ecx, %ecx
	jmp	.L499
	.p2align 5
	.p2align 4,,10
	.p2align 3
.L796:
	addl	$1, %ecx
	addq	$12, %r8
	cmpl	%r10d, %ecx
	je	.L650
.L499:
	cmpl	%r14d, 720356(%r8)
	jne	.L796
	movl	%ecx, 68(%rsi)
	cmpq	%rax, %r11
	jb	.L495
.L816:
	movzbl	1(%rdx,%r9), %ecx
	movzbl	(%rdx,%r9), %r8d
	movq	%rax, 176(%rsp)
	sall	$8, %ecx
	orl	%r8d, %ecx
	cmpw	$-1, %cx
	je	.L797
	movzwl	%cx, %r8d
	addq	$4, %r9
	cmpl	%r8d, g_bin_str_count(%rip)
	jle	.L651
	leaq	g_bin_str_ids(%rip), %rcx
	movl	(%rcx,%r8,4), %ecx
.L501:
	movl	%ecx, 72(%rsi)
	cmpq	%r9, %r11
	jb	.L529
	movzbl	1(%rdx,%rax), %ecx
	movzbl	(%rdx,%rax), %eax
	movq	%r9, 176(%rsp)
	sall	$8, %ecx
	orl	%ecx, %eax
	cmpw	$-1, %ax
	je	.L506
	movzwl	%ax, %eax
	cmpl	%eax, g_bin_str_count(%rip)
	jle	.L506
.L817:
	leaq	g_bin_str_ids(%rip), %rcx
	movl	(%rcx,%rax,4), %eax
.L505:
	movl	%eax, 76(%rsi)
	movq	%r13, %rcx
	call	br_expr
	movq	%rax, 80(%rsi)
	jmp	.L438
	.p2align 4,,10
	.p2align 3
.L442:
	leaq	3(%rax), %r9
	movl	$3, (%rsi)
	cmpq	%r9, %r11
	jb	.L798
	movzbl	2(%rdx,%rax), %ecx
	movzbl	(%rdx,%r8), %r8d
	movq	%r9, 176(%rsp)
	sall	$8, %ecx
	orl	%ecx, %r8d
	cmpw	$-1, %r8w
	je	.L799
	movzwl	%r8w, %r8d
	addq	$5, %rax
	cmpl	%r8d, g_bin_str_count(%rip)
	jle	.L800
.L480:
	leaq	g_bin_str_ids(%rip), %rcx
	movl	(%rcx,%r8,4), %r14d
.L484:
	movl	720220(%r12), %r10d
	testl	%r10d, %r10d
	jle	.L646
.L481:
	movq	%r12, %r8
	xorl	%ecx, %ecx
	jmp	.L486
	.p2align 5
	.p2align 4,,10
	.p2align 3
.L801:
	addl	$1, %ecx
	addq	$20, %r8
	cmpl	%r10d, %ecx
	je	.L646
.L486:
	cmpl	%r14d, 719900(%r8)
	jne	.L801
	movl	%ecx, 48(%rsi)
	cmpq	%rax, %r11
	jb	.L482
.L487:
	movzbl	1(%rdx,%r9), %ecx
	movzbl	(%rdx,%r9), %edx
	movq	%rax, 176(%rsp)
	sall	$8, %ecx
	orl	%ecx, %edx
	cmpw	$-1, %dx
	je	.L491
	movzwl	%dx, %eax
.L488:
	cmpl	%eax, g_bin_str_count(%rip)
	jle	.L491
	leaq	g_bin_str_ids(%rip), %rcx
	movl	(%rcx,%rax,4), %eax
.L490:
	movl	%eax, 52(%rsi)
	leaq	56(%rsi), %rdx
	leaq	64(%rsi), %r9
	movq	%r13, %rcx
	leaq	60(%rsi), %r8
	call	br_to_ref
	jmp	.L438
	.p2align 4,,10
	.p2align 3
.L443:
	leaq	3(%rax), %r9
	movl	$2, (%rsi)
	cmpq	%r9, %r11
	jb	.L802
	movzbl	2(%rdx,%rax), %ecx
	movzbl	(%rdx,%r8), %r8d
	movq	%r9, 176(%rsp)
	sall	$8, %ecx
	orl	%ecx, %r8d
	cmpw	$-1, %r8w
	je	.L803
	movzwl	%r8w, %r8d
	addq	$5, %rax
	cmpl	%r8d, g_bin_str_count(%rip)
	jle	.L804
.L467:
	leaq	g_bin_str_ids(%rip), %rcx
	movl	(%rcx,%r8,4), %r14d
.L471:
	movl	720220(%r12), %r10d
	testl	%r10d, %r10d
	jle	.L642
.L468:
	movq	%r12, %r8
	xorl	%ecx, %ecx
	jmp	.L473
	.p2align 5
	.p2align 4,,10
	.p2align 3
.L805:
	addl	$1, %ecx
	addq	$20, %r8
	cmpl	%r10d, %ecx
	je	.L642
.L473:
	cmpl	%r14d, 719900(%r8)
	jne	.L805
	movl	%ecx, 40(%rsi)
	cmpq	%rax, %r11
	jb	.L469
.L474:
	movzbl	1(%rdx,%r9), %ecx
	movzbl	(%rdx,%r9), %edx
	movq	%rax, 176(%rsp)
	sall	$8, %ecx
	orl	%ecx, %edx
	cmpw	$-1, %dx
	je	.L478
	movzwl	%dx, %eax
.L475:
	cmpl	%eax, g_bin_str_count(%rip)
	jle	.L478
	leaq	g_bin_str_ids(%rip), %rcx
	movl	(%rcx,%rax,4), %eax
.L477:
	movl	%eax, 44(%rsi)
	jmp	.L438
	.p2align 4,,10
	.p2align 3
.L444:
	leaq	3(%rax), %r9
	movl	$1, (%rsi)
	cmpq	%r9, %r11
	jb	.L458
	movzbl	2(%rdx,%rax), %ecx
	movzbl	(%rdx,%r8), %r8d
	movq	%r9, 176(%rsp)
	sall	$8, %ecx
	orl	%r8d, %ecx
	cmpw	$-1, %cx
	je	.L806
	movzwl	%cx, %r10d
	cmpl	%r10d, g_bin_str_count(%rip)
	leaq	5(%rax), %r8
	jle	.L638
	leaq	g_bin_str_ids(%rip), %rcx
	movl	(%rcx,%r10,4), %ecx
.L460:
	movl	%ecx, 24(%rsi)
	cmpq	%r8, %r11
	jb	.L527
	movzbl	4(%rdx,%rax), %eax
	movzbl	(%rdx,%r9), %edx
	movq	%r8, 176(%rsp)
	sall	$8, %eax
	orl	%edx, %eax
	cmpw	$-1, %ax
	je	.L465
	movzwl	%ax, %eax
	cmpl	%eax, g_bin_str_count(%rip)
	jle	.L465
.L824:
	leaq	g_bin_str_ids(%rip), %rcx
	movl	(%rcx,%rax,4), %eax
.L464:
	movl	%eax, 28(%rsi)
	movq	%r13, %rcx
	call	br_expr
	movq	%rax, 32(%rsi)
	jmp	.L438
	.p2align 4,,10
	.p2align 3
.L753:
	movq	%rcx, %rax
.L388:
	movl	$0, 442152(%rbx)
	leaq	2(%rax), %r8
	cmpq	%r8, %rdx
	jb	.L608
	movq	160(%rsp), %r9
	movzbl	1(%r9,%rax), %ecx
	movzbl	(%r9,%rax), %eax
	movq	%r8, 176(%rsp)
	sall	$8, %ecx
	orl	%eax, %ecx
	cmpw	$-1, %cx
	je	.L609
	movzwl	%cx, %ecx
	cmpl	g_bin_str_count(%rip), %ecx
	movq	%r8, %rax
	jge	.L610
.L811:
	movl	0(%rbp,%rcx,4), %ecx
.L395:
	movl	%ecx, 442156(%rbx)
	cmpq	%rdx, %rax
	jnb	.L396
	movq	160(%rsp), %r8
	leaq	1(%rax), %rcx
	movq	%rcx, 176(%rsp)
	movzbl	(%r8,%rax), %r9d
	movl	%r9d, 442240(%rbx)
	cmpq	%rdx, %rcx
	jnb	.L611
	addq	$2, %rax
	movq	%rax, 176(%rsp)
	movzbl	(%r8,%rcx), %r8d
	movl	$1, %ecx
	cmpb	$1, %r8b
	je	.L397
	movl	$2, %ecx
	cmpb	$2, %r8b
	je	.L397
	xorl	%ecx, %ecx
	cmpb	$3, %r8b
	sete	%cl
	leal	(%rcx,%rcx,2), %ecx
.L397:
	leaq	2(%rax), %r8
	movl	%ecx, 442232(%rbx)
	cmpq	%r8, %rdx
	jb	.L615
	movq	160(%rsp), %r9
	movzbl	1(%r9,%rax), %ecx
	movzbl	(%r9,%rax), %eax
	movq	%r8, 176(%rsp)
	sall	$8, %ecx
	orl	%eax, %ecx
	cmpw	$-1, %cx
	je	.L616
	movzwl	%cx, %ecx
	cmpl	%ecx, g_bin_str_count(%rip)
	movq	%r8, %rax
	jle	.L617
.L810:
	movl	0(%rbp,%rcx,4), %ecx
.L399:
	movl	%ecx, 442236(%rbx)
	cmpq	%rdx, %rax
	jnb	.L400
	movq	160(%rsp), %r8
	leaq	1(%rax), %rcx
	movq	%rcx, 176(%rsp)
	movzbl	(%r8,%rax), %r9d
	testb	%r9b, %r9b
	jne	.L401
	movq	%rcx, %rax
.L400:
	leaq	2(%rax), %rcx
	cmpq	%rcx, %rdx
	jb	.L618
	movq	160(%rsp), %r8
	movzbl	1(%r8,%rax), %edx
	movzbl	(%r8,%rax), %eax
	movq	%rcx, 176(%rsp)
	sall	$8, %edx
	orl	%edx, %eax
	cmpw	$-1, %ax
	je	.L405
	movzwl	%ax, %eax
	cmpl	%eax, g_bin_str_count(%rip)
	jle	.L405
.L815:
	movl	0(%rbp,%rax,4), %ecx
.L404:
	call	graph_find_container_by_name
	movq	176(%rsp), %rcx
	movq	168(%rsp), %rdx
	movl	%eax, 442160(%rbx)
.L406:
	cmpq	%rdx, %rcx
	jnb	.L393
	leaq	1(%rcx), %rax
	movq	%rax, 176(%rsp)
	movq	160(%rsp), %rax
	cmpb	$0, (%rax,%rcx)
	je	.L393
	movq	%r13, %rcx
	call	br_expr
	movq	%rax, 442256(%rbx)
	jmp	.L393
	.p2align 4,,10
	.p2align 3
.L591:
	xorl	%ecx, %ecx
	cmpl	%ecx, g_bin_str_count(%rip)
	jg	.L807
.L593:
	movl	$-1, %r10d
	jmp	.L346
	.p2align 4,,10
	.p2align 3
.L348:
	cmpb	$1, %cl
	je	.L808
	cmpb	$2, %cl
	je	.L809
	movq	%r8, %rax
	jmp	.L351
	.p2align 4,,10
	.p2align 3
.L637:
	movl	$-1, %eax
	movl	%eax, 4(%rsi)
	cmpq	%r9, %r11
	jnb	.L453
.L448:
	xorl	%eax, %eax
	jmp	.L454
	.p2align 4,,10
	.p2align 3
.L390:
	cmpb	$3, %r9b
	jne	.L393
	movl	$3, 442152(%rbx)
	movq	%r13, %rcx
	call	br_expr
	movq	%rax, 442264(%rbx)
	jmp	.L393
	.p2align 4,,10
	.p2align 3
.L615:
	xorl	%ecx, %ecx
	cmpl	%ecx, g_bin_str_count(%rip)
	jg	.L810
.L617:
	movl	$-1, %ecx
	jmp	.L399
	.p2align 4,,10
	.p2align 3
.L396:
	movl	$0, 442240(%rbx)
	xorl	%ecx, %ecx
	jmp	.L397
	.p2align 4,,10
	.p2align 3
.L608:
	xorl	%ecx, %ecx
	cmpl	g_bin_str_count(%rip), %ecx
	jl	.L811
.L610:
	movl	$-1, %ecx
	jmp	.L395
	.p2align 4,,10
	.p2align 3
.L401:
	cmpb	$1, %r9b
	je	.L812
	cmpb	$2, %r9b
	jne	.L406
	leaq	3(%rax), %r9
	cmpq	%r9, %rdx
	jb	.L623
	movzbl	2(%r8,%rax), %eax
	movzbl	(%r8,%rcx), %ecx
	movq	%r9, 176(%rsp)
	sall	$8, %eax
	orl	%ecx, %eax
	cmpw	$-1, %ax
	je	.L624
	movzwl	%ax, %eax
	movq	%r9, %rcx
.L413:
	cmpl	%eax, g_bin_str_count(%rip)
	jle	.L625
	leaq	g_bin_str_ids(%rip), %r10
	movl	(%r10,%rax,4), %r9d
.L414:
	movl	720220(%r12), %r10d
	testl	%r10d, %r10d
	jle	.L626
	movq	%r12, %r8
	xorl	%eax, %eax
	jmp	.L416
	.p2align 5
	.p2align 4,,10
	.p2align 3
.L813:
	addl	$1, %eax
	addq	$20, %r8
	cmpl	%eax, %r10d
	je	.L626
.L416:
	cmpl	%r9d, 719900(%r8)
	jne	.L813
	movl	%eax, 442280(%rbx)
	jmp	.L406
	.p2align 4,,10
	.p2align 3
.L789:
	movl	g_bin_str_count(%rip), %edx
	testl	%edx, %edx
	jle	.L814
	movq	%r10, %r9
	xorl	%edx, %edx
	movq	%rax, %r10
	jmp	.L446
	.p2align 4,,10
	.p2align 3
.L618:
	xorl	%eax, %eax
	cmpl	%eax, g_bin_str_count(%rip)
	jg	.L815
.L405:
	movl	$-1, %ecx
	jmp	.L404
	.p2align 4,,10
	.p2align 3
.L808:
	leaq	9(%rax), %r9
	xorl	%eax, %eax
	cmpq	%r9, %rdx
	jb	.L353
	xorl	%edx, %edx
	.p2align 5
	.p2align 4
	.p2align 3
.L354:
	movzbl	1(%r11,%rdx), %r8d
	leal	0(,%rdx,8), %ecx
	addq	$1, %rdx
	salq	%cl, %r8
	orq	%r8, %rax
	cmpq	$8, %rdx
	jne	.L354
	movq	%r9, 176(%rsp)
.L353:
	leaq	152(%rsp), %rdx
	movl	$8, %r8d
	leaq	192(%rsp), %rcx
	movl	%r10d, 80(%rsp)
	movq	%rax, 152(%rsp)
	call	herb_memcpy
	movq	64(%rsp), %rax
	movq	192(%rsp), %rdx
	movl	%esi, %ecx
	leaq	128(%rsp), %r8
	andq	%rdi, %rax
	movq	%rdx, 72(%rsp)
	movl	80(%rsp), %edx
	orq	$2, %rax
	movq	%rax, 64(%rsp)
	movdqa	64(%rsp), %xmm1
	movaps	%xmm1, 128(%rsp)
	call	entity_set_prop
	movq	176(%rsp), %rax
	movq	168(%rsp), %rdx
	jmp	.L351
	.p2align 4,,10
	.p2align 3
.L809:
	leaq	3(%rax), %rcx
	cmpq	%rcx, %rdx
	jb	.L597
	movzbl	2(%r9,%rax), %eax
	movzbl	(%r9,%r8), %edx
	movq	%rcx, 176(%rsp)
	sall	$8, %eax
	orl	%edx, %eax
	cmpw	$-1, %ax
	je	.L358
	movzwl	%ax, %eax
	cmpl	%eax, g_bin_str_count(%rip)
	jle	.L358
.L833:
	leaq	g_bin_str_ids(%rip), %rdx
	movl	(%rdx,%rax,4), %edx
.L357:
	movq	32(%rsp), %r8
	movq	40(%rsp), %r9
	movq	%r8, %rax
	movq	%r9, 40(%rsp)
	andq	%rdi, %rax
	orq	$3, %rax
	movq	%rax, 32(%rsp)
	movq	40(%rsp), %rax
	movq	32(%rsp), %r8
	andq	%rdi, %rax
	orq	%rdx, %rax
	movq	%r8, 32(%rsp)
	movq	%rax, 40(%rsp)
	movdqa	32(%rsp), %xmm2
	movaps	%xmm2, 128(%rsp)
	jmp	.L744
	.p2align 4,,10
	.p2align 3
.L646:
	movl	$-1, %ecx
	movl	%ecx, 48(%rsi)
	cmpq	%rax, %r11
	jnb	.L487
.L482:
	xorl	%eax, %eax
	jmp	.L488
	.p2align 4,,10
	.p2align 3
.L650:
	movl	$-1, %ecx
	movl	%ecx, 68(%rsi)
	cmpq	%rax, %r11
	jnb	.L816
.L495:
	movl	g_bin_str_count(%rip), %r11d
	testl	%r11d, %r11d
	jle	.L530
	movl	g_bin_str_ids(%rip), %eax
	movl	%eax, 72(%rsi)
.L529:
	xorl	%eax, %eax
.L835:
	cmpl	%eax, g_bin_str_count(%rip)
	jg	.L817
.L506:
	movl	$-1, %eax
	jmp	.L505
	.p2align 4,,10
	.p2align 3
.L642:
	movl	$-1, %ecx
	movl	%ecx, 40(%rsi)
	cmpq	%rax, %r11
	jnb	.L474
.L469:
	xorl	%eax, %eax
	jmp	.L475
	.p2align 4,,10
	.p2align 3
.L421:
	movl	$0, 442232(%rbx)
.L422:
	movl	$0, 442228(%rbx)
	jmp	.L393
	.p2align 4,,10
	.p2align 3
.L627:
	xorl	%eax, %eax
	cmpl	g_bin_str_count(%rip), %eax
	jl	.L818
.L629:
	movl	$-1, %eax
	jmp	.L420
	.p2align 4,,10
	.p2align 3
.L631:
	xorl	%eax, %eax
	cmpl	g_bin_str_count(%rip), %eax
	jl	.L819
.L431:
	movl	$-1, %ecx
	jmp	.L430
	.p2align 4,,10
	.p2align 3
.L343:
	addl	$1, %ebp
	cmpw	%bp, 56(%rsp)
	je	.L219
	movq	%rcx, %rax
	leaq	2(%rax), %r9
	cmpq	%r9, %rdx
	jnb	.L820
.L324:
	movl	g_bin_str_count(%rip), %ecx
	testl	%ecx, %ecx
	jle	.L821
	movq	%rax, %rcx
	movl	g_bin_str_ids(%rip), %ebx
	leaq	g_bin_str_ids(%rip), %r8
	xorl	%eax, %eax
	jmp	.L326
	.p2align 4,,10
	.p2align 3
.L601:
	xorl	%eax, %eax
	cmpl	%eax, g_bin_str_count(%rip)
	jg	.L822
.L372:
	movl	$-1, %ecx
	jmp	.L371
	.p2align 4,,10
	.p2align 3
.L602:
	xorl	%eax, %eax
	cmpl	%eax, g_bin_str_count(%rip)
	jg	.L823
.L376:
	movl	$-1, %eax
	jmp	.L375
	.p2align 4,,10
	.p2align 3
.L385:
	movl	$0, 444084(%r14)
.L386:
	imulq	$1960, %rax, %rdx
	movl	$0, 443240(%r12,%rdx)
.L434:
	imulq	$1960, %rax, %rax
	movl	$0, 444080(%r12,%rax)
	jmp	.L436
	.p2align 4,,10
	.p2align 3
.L381:
	movl	g_bin_str_count(%rip), %r9d
	testl	%r9d, %r9d
	jle	.L533
	movl	g_bin_str_ids(%rip), %r9d
	movl	%r9d, 442128(%rdx)
.L534:
	movq	%r8, %r11
	xorl	%edx, %edx
	jmp	.L384
.L656:
	movq	%rbx, %rax
	movq	%r8, %rbx
.L520:
	movl	52(%rsp), %r8d
	testl	%r8d, %r8d
	jle	.L724
	xorl	%r8d, %r8d
	jmp	.L320
	.p2align 4
	.p2align 4,,10
	.p2align 3
.L319:
	addq	$1, %r8
	cmpq	%r8, %rbp
	je	.L724
.L320:
	cmpl	%r10d, (%rdi,%r8,8)
	jne	.L319
	leaq	(%r9,%r9,2), %r10
	movl	%r8d, 720360(%r12,%r10,4)
	cmpq	%rax, %rdx
	jnb	.L515
.L762:
	movq	%rbx, %rax
	xorl	%r8d, %r8d
	jmp	.L514
.L761:
	leaq	4(%rax), %rbx
.L309:
	leaq	(%r9,%r9,2), %rax
	movl	$-1, 720356(%r12,%rax,4)
	cmpq	%rbx, %rdx
	jnb	.L311
	testl	%r13d, %r13d
	jle	.L723
	leaq	g_bin_str_ids(%rip), %r14
.L310:
	movl	(%r14), %r10d
	leaq	(%r9,%r9,2), %rax
	movl	$-1, 720360(%r12,%rax,4)
	testl	%r10d, %r10d
	jns	.L656
	movq	%r8, %rax
	xorl	%r8d, %r8d
	jmp	.L514
	.p2align 4,,10
	.p2align 3
.L331:
	cmpb	$1, %r8b
	jne	.L335
	leaq	3(%rcx), %r8
	cmpq	%r8, %rdx
	jb	.L589
	movzbl	2(%r9,%rcx), %edx
	movzbl	(%r9,%rax), %eax
	movq	%r8, 176(%rsp)
	sall	$8, %edx
	orl	%edx, %eax
	cmpw	$-1, %ax
	je	.L340
	movzwl	%ax, %eax
.L337:
	cmpl	%eax, g_bin_str_count(%rip)
	jle	.L340
	leaq	g_bin_str_ids(%rip), %r8
	movl	(%r8,%rax,4), %ecx
.L339:
	call	graph_find_entity_by_name
	movq	176(%rsp), %rdx
	movl	%eax, %ecx
	leaq	2(%rdx), %r8
	cmpq	%r8, 168(%rsp)
	jb	.L590
	movq	160(%rsp), %r9
	movzbl	1(%r9,%rdx), %eax
	movzbl	(%r9,%rdx), %edx
	movq	%r8, 176(%rsp)
	sall	$8, %eax
	orl	%edx, %eax
	cmpw	$-1, %ax
	je	.L335
	movzwl	%ax, %eax
.L341:
	cmpl	%eax, g_bin_str_count(%rip)
	jle	.L335
	leaq	g_bin_str_ids(%rip), %r8
	movl	(%r8,%rax,4), %edx
	movl	%ecx, %eax
	orl	%edx, %eax
	js	.L335
	call	get_scoped_container
	movl	%eax, %r8d
	jmp	.L334
	.p2align 4,,10
	.p2align 3
.L775:
	leaq	2(%rax), %r8
	movl	$0, 8(%r9)
	cmpq	%r8, %rdx
	jb	.L555
	movq	%rax, %r11
	movq	%r8, %rax
	jmp	.L250
.L760:
	call	graph_find_container_by_name
	movl	%eax, %r8d
	jmp	.L334
.L458:
	movl	g_bin_str_count(%rip), %r14d
	testl	%r14d, %r14d
	jle	.L528
	movl	g_bin_str_ids(%rip), %eax
	movl	%eax, 24(%rsi)
.L527:
	xorl	%eax, %eax
.L836:
	cmpl	%eax, g_bin_str_count(%rip)
	jg	.L824
.L465:
	movl	$-1, %eax
	jmp	.L464
.L793:
	movl	g_bin_str_count(%rip), %r10d
	testl	%r10d, %r10d
	jle	.L825
	movq	%r9, %rax
	movq	%r8, %r9
	xorl	%r8d, %r8d
	jmp	.L493
.L652:
	xorl	%eax, %eax
	cmpl	%eax, g_bin_str_count(%rip)
	jg	.L826
.L510:
	movl	$-1, %eax
	jmp	.L509
.L798:
	movl	g_bin_str_count(%rip), %r14d
	testl	%r14d, %r14d
	jle	.L827
	movq	%r9, %rax
	movq	%r8, %r9
	xorl	%r8d, %r8d
	jmp	.L480
.L802:
	movl	g_bin_str_count(%rip), %eax
	testl	%eax, %eax
	jle	.L828
	movq	%r9, %rax
	movq	%r8, %r9
	xorl	%r8d, %r8d
	jmp	.L467
.L812:
	leaq	3(%rax), %r11
	cmpq	%r11, %rdx
	jb	.L408
	movzbl	2(%r8,%rax), %r9d
	movzbl	(%r8,%rcx), %ecx
	movq	%r11, 176(%rsp)
	sall	$8, %r9d
	orl	%ecx, %r9d
	cmpw	$-1, %r9w
	je	.L829
	movzwl	%r9w, %r9d
	cmpl	%r9d, g_bin_str_count(%rip)
	leaq	5(%rax), %rcx
	jle	.L619
	leaq	g_bin_str_ids(%rip), %r10
	movl	(%r10,%r9,4), %r9d
.L410:
	movl	%r9d, 442272(%rbx)
	cmpq	%rcx, %rdx
	jb	.L620
	movzbl	4(%r8,%rax), %eax
	movzbl	(%r8,%r11), %r8d
	movq	%rcx, 176(%rsp)
	sall	$8, %eax
	orl	%r8d, %eax
	cmpw	$-1, %ax
	je	.L622
	movzwl	%ax, %eax
.L411:
	cmpl	%eax, g_bin_str_count(%rip)
	jle	.L622
	leaq	g_bin_str_ids(%rip), %r10
	movl	(%r10,%rax,4), %eax
.L412:
	movl	%eax, 442276(%rbx)
	jmp	.L406
.L764:
	leaq	4(%rax), %r11
.L302:
	movl	$-1, (%r9)
	cmpq	%r11, %rdx
	jnb	.L304
	movq	%rbp, %rax
	xorl	%r8d, %r8d
	jmp	.L305
	.p2align 4,,10
	.p2align 3
.L557:
	xorl	%r8d, %r8d
	movq	%r11, %rax
	cmpl	%r8d, %edi
	jg	.L249
.L559:
	movl	$-1, %r8d
	jmp	.L253
.L654:
	movl	$-1, %ebx
	movl	$-1, %esi
.L743:
	xorl	%eax, %eax
	jmp	.L332
.L765:
	movq	%rbp, %rax
	xorl	%r8d, %r8d
	jmp	.L303
.L778:
	movslq	584728(%r12), %r13
	movl	$1, %r10d
	movl	%r8d, 571928(%r12,%r13,4)
	leaq	0(%r13,%r13,2), %r8
	leal	1(%r13), %r9d
	addq	$146116, %r13
	salq	$6, %r8
	movl	%r9d, 584728(%r12)
	leaq	572184(%r12,%r8), %r9
	jmp	.L244
	.p2align 4,,10
	.p2align 3
.L831:
	movzbl	1(%rcx,%rax), %r8d
	movzbl	(%rcx,%rax), %eax
	movq	%r14, 176(%rsp)
	sall	$8, %r8d
	orl	%eax, %r8d
	cmpw	$-1, %r8w
	je	.L544
	movzwl	%r8w, %r8d
	movq	%r14, %rax
	cmpl	%r8d, %edi
	jle	.L237
.L832:
	movl	(%rsi,%r8,4), %r8d
	movl	%r8d, (%r9)
	cmpq	%rdx, %rax
	jnb	.L830
.L238:
	leaq	1(%rax), %r14
	movq	%r14, 176(%rsp)
	cmpb	$0, (%rcx,%rax)
	setne	%al
	movzbl	%al, %eax
	movl	%eax, 4(%r9)
	leaq	2(%r14), %rax
	cmpq	%rax, %rdx
	jb	.L547
.L240:
	movzbl	1(%rcx,%r14), %r8d
	movzbl	(%rcx,%r14), %r14d
	movq	%rax, 176(%rsp)
	sall	$8, %r8d
	orl	%r14d, %r8d
	cmpw	$-1, %r8w
	je	.L549
	movzwl	%r8w, %r8d
	cmpl	%r8d, %edi
	jle	.L549
.L239:
	movl	(%rsi,%r8,4), %r8d
.L243:
	movl	%r8d, 8(%r9)
	addq	$12, %r9
	cmpq	%rbp, %r10
	je	.L235
	addq	$1, %r10
.L244:
	leaq	2(%rax), %r14
	movl	%r10d, 8(%r12,%r13,4)
	cmpq	%r14, %rdx
	jnb	.L831
	xorl	%r8d, %r8d
	cmpl	%r8d, %edi
	jg	.L832
.L237:
	movl	$-1, (%r9)
	cmpq	%rdx, %rax
	jb	.L238
	movq	%rax, %r14
	xorl	%eax, %eax
	movl	%eax, 4(%r9)
	leaq	2(%r14), %rax
	cmpq	%rax, %rdx
	jnb	.L240
	.p2align 4
	.p2align 3
.L547:
	xorl	%r8d, %r8d
	movq	%r14, %rax
	cmpl	%r8d, %edi
	jg	.L239
.L549:
	movl	$-1, %r8d
	jmp	.L243
	.p2align 4,,10
	.p2align 3
.L830:
	leaq	2(%rax), %r8
	movl	$0, 4(%r9)
	cmpq	%r8, %rdx
	jb	.L545
	movq	%rax, %r14
	movq	%r8, %rax
	jmp	.L240
.L545:
	xorl	%r8d, %r8d
	jmp	.L239
.L457:
	movl	$-1, %eax
	jmp	.L456
.L597:
	xorl	%eax, %eax
	cmpl	%eax, g_bin_str_count(%rip)
	jg	.L833
.L358:
	movl	$4294967295, %edx
	jmp	.L357
.L555:
	xorl	%r8d, %r8d
	jmp	.L249
.L791:
	movl	$-1, %r8d
	jmp	.L450
.L408:
	movl	g_bin_str_count(%rip), %r10d
	testl	%r10d, %r10d
	jle	.L531
	movl	g_bin_str_ids(%rip), %eax
	movl	%eax, 442272(%rbx)
	xorl	%eax, %eax
	jmp	.L411
.L814:
	movl	442120(%r12), %ecx
	movq	%r10, %r9
	movl	$-1, %r8d
	movq	%rax, %r10
	testl	%ecx, %ecx
	jg	.L447
	movl	$-1, 4(%rsi)
	xorl	%eax, %eax
	jmp	.L454
	.p2align 4,,10
	.p2align 3
.L592:
	movq	%r8, %rax
	movl	$-1, %r10d
	jmp	.L346
.L626:
	movl	$-1, %eax
	movl	%eax, 442280(%rbx)
	jmp	.L406
.L603:
	movq	%r9, %rax
	xorl	%ecx, %ecx
	jmp	.L378
.L581:
	movl	$-1, %r8d
	jmp	.L316
.L478:
	movl	$-1, %eax
	jmp	.L477
.L491:
	movl	$-1, %eax
	jmp	.L490
.L766:
	movl	$-1, %r8d
	jmp	.L300
.L587:
	movl	$-1, %esi
	jmp	.L329
.L325:
	leaq	4(%rax), %rcx
	movl	$-1, %ebx
	cmpq	%rcx, %rdx
	jnb	.L327
	movl	g_bin_str_count(%rip), %r8d
	movq	%r9, %rcx
	xorl	%eax, %eax
	jmp	.L328
.L313:
	leaq	4(%r8), %rax
.L315:
	leaq	(%r9,%r9,2), %r8
	movl	$-1, 720360(%r12,%r8,4)
	cmpq	%rax, %rdx
	jnb	.L515
	movq	%rbx, %rax
	xorl	%r8d, %r8d
	jmp	.L322
.L623:
	xorl	%eax, %eax
	jmp	.L413
.L600:
	movl	$-1, %eax
	jmp	.L363
.L605:
	movl	$-1, %edx
	jmp	.L383
.L561:
	movl	$-1, %eax
	jmp	.L259
.L589:
	xorl	%eax, %eax
	jmp	.L337
.L590:
	xorl	%eax, %eax
	jmp	.L341
.L566:
	movl	$-1, (%r8)
	addq	$4, %r8
	movq	%r10, %rdx
	cmpq	%r8, %r11
	jne	.L274
	jmp	.L271
.L609:
	movq	%r8, %rax
	movl	$-1, %ecx
	jmp	.L395
.L651:
	movl	$-1, %ecx
	jmp	.L501
.L638:
	movl	$-1, %ecx
	jmp	.L460
.L804:
	movl	$-1, %r14d
	jmp	.L471
.L800:
	movl	$-1, %r14d
	jmp	.L484
.L795:
	movl	$-1, %r14d
	jmp	.L497
.L616:
	movq	%r8, %rax
	movl	$-1, %ecx
	jmp	.L399
.L790:
	leaq	4(%rax), %r9
	movl	$-1, %r8d
	jmp	.L450
.L526:
	movl	$-1, 719900(%r12,%rax,4)
	xorl	%eax, %eax
	jmp	.L834
.L821:
	cmpq	%rdx, %rax
	jnb	.L654
	movq	%rax, %rcx
	movl	$-1, %ebx
	movl	$-1, %esi
	jmp	.L517
.L767:
	movl	$-1, (%r9)
	movl	$-1, %r8d
	jmp	.L300
.L518:
	movl	$-1, 423944(%r12,%r13)
	jmp	.L519
.L533:
	movl	$-1, 442128(%rdx)
	jmp	.L534
.L622:
	movl	$-1, %eax
	jmp	.L412
.L530:
	movl	$-1, 72(%rsi)
	xorl	%eax, %eax
	jmp	.L835
.L828:
	movl	720220(%r12), %r10d
	movq	%r9, %rax
	movl	$-1, %r14d
	movq	%r8, %r9
	testl	%r10d, %r10d
	jg	.L468
	movl	$-1, 40(%rsi)
	xorl	%eax, %eax
	jmp	.L475
	.p2align 4,,10
	.p2align 3
.L827:
	movl	720220(%r12), %r10d
	movq	%r9, %rax
	movl	$-1, %r14d
	movq	%r8, %r9
	testl	%r10d, %r10d
	jg	.L481
	movl	$-1, 48(%rsi)
	xorl	%eax, %eax
	jmp	.L488
	.p2align 4,,10
	.p2align 3
.L825:
	movl	720548(%r12), %r10d
	movq	%r9, %rax
	movl	$-1, %r14d
	movq	%r8, %r9
	testl	%r10d, %r10d
	jg	.L494
	movl	$-1, 68(%rsi)
	jmp	.L495
	.p2align 4,,10
	.p2align 3
.L528:
	movl	$-1, 24(%rsi)
	xorl	%eax, %eax
	jmp	.L836
.L205:
	leaq	.LC17(%rip), %rdx
	xorl	%ecx, %ecx
	call	herb_error
.L204:
	movl	$-1, %eax
	jmp	.L202
.L268:
	cmpq	%rcx, %rdx
	jb	.L513
	jmp	.L266
.L752:
	leaq	4(%r8), %r11
	movl	$-1, %edx
	jmp	.L383
.L554:
	movq	%r11, %rax
	jmp	.L247
.L544:
	movq	%r14, %rax
	jmp	.L237
.L628:
	movq	%r9, %rcx
	movl	$-1, %eax
	jmp	.L420
.L756:
	leaq	4(%r8), %r11
	movl	$-1, %eax
	jmp	.L363
.L768:
	leaq	4(%rdx), %r8
	movl	$-1, %eax
	jmp	.L259
.L575:
	movq	%r11, %rax
	movl	$-1, %r8d
	jmp	.L300
.L619:
	movl	$-1, %r9d
	jmp	.L410
.L625:
	movl	$-1, %r9d
	jmp	.L414
.L799:
	addq	$5, %rax
	movl	$-1, %r14d
	jmp	.L484
.L803:
	addq	$5, %rax
	movl	$-1, %r14d
	jmp	.L471
.L806:
	leaq	5(%rax), %r8
	movl	$-1, %ecx
	jmp	.L460
.L567:
	xorl	%r8d, %r8d
	jmp	.L275
.L797:
	addq	$4, %r9
	movl	$-1, %ecx
	jmp	.L501
.L750:
	leaq	.LC18(%rip), %rdx
	xorl	%ecx, %ecx
	call	herb_error
	jmp	.L204
.L340:
	movl	$-1, %ecx
	jmp	.L339
.L794:
	addq	$5, %rax
	movl	$-1, %r14d
	jmp	.L497
.L531:
	movl	$-1, 442272(%rbx)
	xorl	%eax, %eax
	jmp	.L411
.L624:
	movq	%r9, %rcx
	movl	$-1, %r9d
	jmp	.L414
.L749:
	leaq	.LC16(%rip), %rdx
	xorl	%ecx, %ecx
	call	herb_error
	jmp	.L204
.L606:
	movq	%r10, %r11
	xorl	%edx, %edx
	jmp	.L384
.L759:
	movq	%r9, %rcx
	xorl	%eax, %eax
	jmp	.L326
.L620:
	movq	%r11, %rcx
	xorl	%eax, %eax
	jmp	.L411
	.p2align 4,,10
	.p2align 3
.L829:
	leaq	5(%rax), %rcx
	movl	$-1, %r9d
	jmp	.L410
.L723:
	movq	%r8, %rax
	jmp	.L521
.L562:
	movq	%r10, %r8
	xorl	%eax, %eax
	jmp	.L260
.L611:
	movq	%rcx, %rax
	xorl	%ecx, %ecx
	jmp	.L397
	.seh_endproc
	.section .rdata,"dr"
.LC24:
	.ascii "null\0"
.LC25:
	.ascii "  \"\0"
.LC26:
	.ascii "\": {\"location\": \"\0"
.LC27:
	.ascii ", \"\0"
.LC28:
	.ascii "\": \0"
.LC29:
	.ascii "%lld\0"
.LC30:
	.ascii "%g\0"
.LC31:
	.ascii "\12}\12\0"
	.text
	.p2align 4
	.globl	herb_state
	.def	herb_state;	.scl	2;	.type	32;	.endef
	.seh_proc	herb_state
herb_state:
	pushq	%r15
	.seh_pushreg	%r15
	pushq	%r14
	.seh_pushreg	%r14
	pushq	%r13
	.seh_pushreg	%r13
	pushq	%r12
	.seh_pushreg	%r12
	pushq	%rbp
	.seh_pushreg	%rbp
	pushq	%rdi
	.seh_pushreg	%rdi
	pushq	%rsi
	.seh_pushreg	%rsi
	pushq	%rbx
	.seh_pushreg	%rbx
	subq	$88, %rsp
	.seh_stackalloc	88
	.seh_endprologue
	movq	%rcx, %rsi
	movl	%edx, %r13d
	cmpl	$1, %edx
	jle	.L839
	movb	$123, (%rcx)
	cmpl	$2, %edx
	je	.L839
	movb	$10, 1(%rcx)
.L839:
	movl	352256+g_graph(%rip), %edx
	leal	-1(%r13), %r15d
	testl	%edx, %edx
	jle	.L893
	movslq	567572+g_graph(%rip), %rax
	leaq	g_graph(%rip), %r12
	leaq	.LC24(%rip), %rdi
	testl	%eax, %eax
	js	.L842
	imulq	$280, %rax, %rax
	movl	352264(%rax,%r12), %ecx
	call	str_of
	movq	%rax, %rdi
.L842:
	movq	$0, 40(%rsp)
	movl	$2, %ebx
.L843:
	movslq	%ebx, %rbp
	leaq	.LC25(%rip), %rcx
	movl	$32, %edx
	leaq	3(%rbp), %r8
	movq	%rbp, %rax
	subq	%rbp, %rcx
.L847:
	cmpl	%eax, %r15d
	jle	.L846
	movb	%dl, (%rsi,%rax)
.L846:
	movzbl	1(%rcx,%rax), %edx
	addq	$1, %rax
	cmpq	%r8, %rax
	jne	.L847
	movl	8(%r12), %ecx
	call	str_of
	movzbl	(%rax), %ecx
	testb	%cl, %cl
	je	.L848
	leal	4(%rbx), %edx
	movslq	%edx, %rdx
	subq	%rdx, %rbp
	subq	%rdx, %rax
	leaq	(%rsi,%rbp), %r9
	jmp	.L850
	.p2align 5
	.p2align 4,,10
	.p2align 3
.L895:
	addq	$1, %rdx
.L850:
	leal	-1(%rdx), %r8d
	cmpl	%r8d, %r15d
	jle	.L849
	movb	%cl, 3(%r9,%rdx)
.L849:
	movzbl	1(%rdx,%rax), %ecx
	testb	%cl, %cl
	jne	.L895
.L851:
	movslq	%edx, %r10
	leaq	.LC26(%rip), %r8
	movl	$34, %ecx
	leaq	17(%r10), %r9
	movq	%r10, %rax
	subq	%r10, %r8
	.p2align 5
	.p2align 4
	.p2align 3
.L853:
	cmpl	%eax, %r15d
	jle	.L852
	movb	%cl, (%rsi,%rax)
.L852:
	movzbl	1(%r8,%rax), %ecx
	addq	$1, %rax
	cmpq	%r9, %rax
	jne	.L853
	movzbl	(%rdi), %ecx
	testb	%cl, %cl
	je	.L854
	leal	18(%rdx), %eax
	cltq
	subq	%rax, %r10
	subq	%rax, %rdi
	leaq	(%rsi,%r10), %r8
	jmp	.L856
	.p2align 5
	.p2align 4,,10
	.p2align 3
.L896:
	addq	$1, %rax
.L856:
	leal	-1(%rax), %edx
	cmpl	%edx, %r15d
	jle	.L855
	movb	%cl, 17(%r8,%rax)
.L855:
	movzbl	1(%rax,%rdi), %ecx
	testb	%cl, %cl
	jne	.L896
.L857:
	cmpl	%eax, %r15d
	jle	.L858
	movslq	%eax, %rdx
	movb	$34, (%rsi,%rdx)
.L858:
	leal	1(%rax), %r14d
	movl	336(%r12), %eax
	testl	%eax, %eax
	jle	.L859
	movl	%r13d, 168(%rsp)
	leaq	80(%r12), %rdi
	xorl	%ebx, %ebx
	movl	%r14d, %r13d
	.p2align 4
	.p2align 3
.L860:
	movslq	%r13d, %rbp
	leaq	.LC27(%rip), %rcx
	movl	$44, %edx
	leaq	3(%rbp), %r8
	movq	%rbp, %rax
	subq	%rbp, %rcx
.L862:
	cmpl	%eax, %r15d
	jle	.L861
	movb	%dl, (%rsi,%rax)
.L861:
	movzbl	1(%rcx,%rax), %edx
	addq	$1, %rax
	cmpq	%r8, %rax
	jne	.L862
	movl	12(%r12,%rbx,4), %ecx
	call	str_of
	movzbl	(%rax), %r8d
	testb	%r8b, %r8b
	je	.L863
	leal	4(%r13), %edx
	movslq	%edx, %rdx
	subq	%rdx, %rbp
	subq	%rdx, %rax
	leaq	(%rsi,%rbp), %r9
	jmp	.L865
	.p2align 5
	.p2align 4,,10
	.p2align 3
.L897:
	addq	$1, %rdx
.L865:
	leal	-1(%rdx), %ecx
	cmpl	%ecx, %r15d
	jle	.L864
	movb	%r8b, 3(%r9,%rdx)
.L864:
	movzbl	1(%rdx,%rax), %r8d
	testb	%r8b, %r8b
	jne	.L897
	movl	%edx, %ebp
.L866:
	movslq	%ebp, %r14
	leaq	.LC28(%rip), %rcx
	movl	$34, %edx
	leaq	3(%r14), %r8
	movq	%r14, %rax
	subq	%r14, %rcx
.L868:
	cmpl	%eax, %r15d
	jle	.L867
	movb	%dl, (%rsi,%rax)
.L867:
	movzbl	1(%rcx,%rax), %edx
	addq	$1, %rax
	cmpq	%rax, %r8
	jne	.L868
	movl	(%rdi), %eax
	movq	8(%rdi), %rcx
	leal	3(%rbp), %r13d
	cmpl	$1, %eax
	je	.L919
	cmpl	$2, %eax
	je	.L920
	cmpl	$3, %eax
	je	.L921
	leaq	.LC24(%rip), %rax
	movslq	%r13d, %r10
	movl	$110, %edx
	leaq	4(%rax), %rcx
.L886:
	cmpl	%r10d, %r15d
	jle	.L885
	movb	%dl, (%rsi,%r10)
.L885:
	addq	$1, %rax
	addq	$1, %r10
	movzbl	(%rax), %edx
	cmpq	%rcx, %rax
	jne	.L886
	leal	7(%rbp), %r13d
.L873:
	addq	$1, %rbx
	addq	$16, %rdi
	cmpl	%ebx, 336(%r12)
	jg	.L860
	movl	%r13d, %r14d
	movl	168(%rsp), %r13d
.L859:
	cmpl	%r14d, %r15d
	jle	.L887
	movslq	%r14d, %rax
	movb	$125, (%rsi,%rax)
.L887:
	leaq	g_graph(%rip), %rbx
	addq	$1, 40(%rsp)
	leal	1(%r14), %ebp
	movq	40(%rsp), %rax
	cmpl	%eax, 352256(%rbx)
	jle	.L841
	leaq	567572(%rbx), %rdi
	addq	$344, %r12
	movslq	(%rdi,%rax,4), %rax
	leaq	.LC24(%rip), %rdi
	testl	%eax, %eax
	js	.L888
	imulq	$280, %rax, %rax
	movl	352264(%rbx,%rax), %ecx
	call	str_of
	movq	%rax, %rdi
.L888:
	cmpl	%ebp, %r15d
	jle	.L844
	movslq	%ebp, %rbp
	movb	$44, (%rsi,%rbp)
.L844:
	leal	2(%r14), %eax
	cmpl	%eax, %r15d
	jle	.L845
	cltq
	movb	$10, (%rsi,%rax)
.L845:
	leal	3(%r14), %ebx
	jmp	.L843
	.p2align 4,,10
	.p2align 3
.L921:
	cmpl	%r13d, %r15d
	jle	.L879
	movslq	%r13d, %r10
	movb	$34, (%rsi,%r10)
.L879:
	call	str_of
	movzbl	(%rax), %ecx
	testb	%cl, %cl
	je	.L880
	leal	5(%rbp), %edx
	movslq	%edx, %rdx
	subq	%rdx, %r14
	subq	%rdx, %rax
	addq	%rsi, %r14
	jmp	.L882
	.p2align 5
	.p2align 4,,10
	.p2align 3
.L898:
	addq	$1, %rdx
.L882:
	leal	-1(%rdx), %r8d
	cmpl	%r8d, %r15d
	jle	.L881
	movb	%cl, 4(%r14,%rdx)
.L881:
	movzbl	1(%rdx,%rax), %ecx
	testb	%cl, %cl
	jne	.L898
.L883:
	cmpl	%edx, %r15d
	jle	.L884
	movslq	%edx, %rax
	movb	$34, (%rsi,%rax)
.L884:
	leal	1(%rdx), %r13d
	jmp	.L873
	.p2align 4,,10
	.p2align 3
.L863:
	leal	3(%r13), %ebp
	jmp	.L866
.L919:
	leaq	48(%rsp), %rbp
	movq	%rcx, %r9
	movl	$24, %edx
	leaq	.LC29(%rip), %r8
	movq	%rbp, %rcx
	call	herb_snprintf
	movzbl	48(%rsp), %edx
	testb	%dl, %dl
	je	.L873
	leaq	3(%rsi,%r14), %rcx
	movq	%rbp, %rax
	.p2align 5
	.p2align 4
	.p2align 3
.L872:
	cmpl	%r13d, %r15d
	jle	.L871
	movb	%dl, (%rcx)
.L871:
	movzbl	1(%rax), %edx
	addq	$1, %rax
	addl	$1, %r13d
	addq	$1, %rcx
	testb	%dl, %dl
	jne	.L872
	jmp	.L873
.L920:
	leaq	48(%rsp), %rbp
	movq	%rcx, %r9
	movq	%rcx, %xmm3
	movl	$32, %edx
	leaq	.LC30(%rip), %r8
	movq	%rbp, %rcx
	call	herb_snprintf
	movzbl	48(%rsp), %edx
	testb	%dl, %dl
	je	.L873
	leaq	3(%rsi,%r14), %rcx
	movq	%rbp, %rax
	.p2align 5
	.p2align 4
	.p2align 3
.L877:
	cmpl	%r13d, %r15d
	jle	.L876
	movb	%dl, (%rcx)
.L876:
	movzbl	1(%rax), %edx
	addq	$1, %rax
	addl	$1, %r13d
	addq	$1, %rcx
	testb	%dl, %dl
	jne	.L877
	jmp	.L873
.L880:
	leal	4(%rbp), %edx
	jmp	.L883
.L893:
	movl	$2, %ebp
.L841:
	movslq	%ebp, %rax
	leaq	.LC31(%rip), %rcx
	movl	$10, %r9d
	leaq	3(%rax), %r10
	subq	%rax, %rcx
.L890:
	cmpl	%eax, %r15d
	jle	.L889
	movb	%r9b, (%rsi,%rax)
.L889:
	movzbl	1(%rcx,%rax), %r9d
	addq	$1, %rax
	cmpq	%r10, %rax
	jne	.L890
	addl	$3, %ebp
	cmpl	%ebp, %r13d
	jle	.L891
	movb	$0, (%rsi,%rax)
.L837:
	movl	%ebp, %eax
	addq	$88, %rsp
	popq	%rbx
	popq	%rsi
	popq	%rdi
	popq	%rbp
	popq	%r12
	popq	%r13
	popq	%r14
	popq	%r15
	ret
.L854:
	leal	17(%rdx), %eax
	jmp	.L857
.L848:
	leal	3(%rbx), %edx
	jmp	.L851
.L891:
	testl	%r13d, %r13d
	jle	.L837
	movslq	%r13d, %r8
	movb	$0, -1(%rsi,%r8)
	jmp	.L837
	.seh_endproc
	.p2align 4
	.globl	herb_init
	.def	herb_init;	.scl	2;	.type	32;	.endef
	.seh_proc	herb_init
herb_init:
	pushq	%rbx
	.seh_pushreg	%rbx
	subq	$32, %rsp
	.seh_stackalloc	32
	.seh_endprologue
	movq	%rcx, %rax
	movq	%r8, %rbx
	leaq	arena_storage.0(%rip), %rcx
	movq	%rdx, %r8
	movq	%rax, %rdx
	movq	%rcx, g_arena(%rip)
	call	herb_arena_init
	movq	%rbx, %rcx
	call	herb_set_error_handler
	movl	$0, g_string_count(%rip)
	movl	$0, g_expr_count(%rip)
	addq	$32, %rsp
	popq	%rbx
	ret
	.seh_endproc
	.section .rdata,"dr"
	.align 8
.LC32:
	.ascii "JSON loading disabled (HERB_BINARY_ONLY)\0"
	.text
	.p2align 4
	.globl	herb_load
	.def	herb_load;	.scl	2;	.type	32;	.endef
	.seh_proc	herb_load
herb_load:
	subq	$40, %rsp
	.seh_stackalloc	40
	.seh_endprologue
	cmpq	$3, %rdx
	jbe	.L924
	cmpb	$72, (%rcx)
	jne	.L924
	cmpb	$69, 1(%rcx)
	jne	.L924
	cmpb	$82, 2(%rcx)
	jne	.L924
	cmpb	$66, 3(%rcx)
	jne	.L924
	addq	$40, %rsp
	jmp	load_program_binary
	.p2align 4,,10
	.p2align 3
.L924:
	leaq	.LC32(%rip), %rdx
	xorl	%ecx, %ecx
	call	herb_error
	movl	$-1, %eax
	addq	$40, %rsp
	ret
	.seh_endproc
	.p2align 4
	.globl	herb_create
	.def	herb_create;	.scl	2;	.type	32;	.endef
	.seh_proc	herb_create
herb_create:
	pushq	%rdi
	.seh_pushreg	%rdi
	pushq	%rsi
	.seh_pushreg	%rsi
	pushq	%rbx
	.seh_pushreg	%rbx
	subq	$32, %rsp
	.seh_stackalloc	32
	.seh_endprologue
	movq	%rcx, %rdi
	movq	%r8, %rcx
	movq	%rdx, %rsi
	call	intern
	movl	%eax, %ecx
	call	graph_find_container_by_name
	movl	%eax, %ebx
	testl	%eax, %eax
	js	.L926
	movq	%rdi, %rcx
	call	intern
	movq	%rsi, %rcx
	movl	%eax, %edi
	call	intern
	movl	%ebx, %r8d
	movl	%edi, %edx
	movl	%eax, %ecx
	addq	$32, %rsp
	popq	%rbx
	popq	%rsi
	popq	%rdi
	jmp	create_entity
	.p2align 4,,10
	.p2align 3
.L926:
	movl	$-1, %eax
	addq	$32, %rsp
	popq	%rbx
	popq	%rsi
	popq	%rdi
	ret
	.seh_endproc
	.p2align 4
	.globl	herb_set_prop_int
	.def	herb_set_prop_int;	.scl	2;	.type	32;	.endef
	.seh_proc	herb_set_prop_int
herb_set_prop_int:
	pushq	%rdi
	.seh_pushreg	%rdi
	pushq	%rsi
	.seh_pushreg	%rsi
	pushq	%rbx
	.seh_pushreg	%rbx
	subq	$32, %rsp
	.seh_stackalloc	32
	.seh_endprologue
	movq	%r8, %rsi
	testl	%ecx, %ecx
	js	.L930
	cmpl	%ecx, 352256+g_graph(%rip)
	leaq	g_graph(%rip), %rbx
	jle	.L930
	movslq	%ecx, %rdi
	movq	%rdx, %rcx
	call	intern
	imulq	$344, %rdi, %r10
	movl	%eax, %r8d
	xorl	%eax, %eax
	leaq	(%rbx,%r10), %rcx
	movl	336(%rcx), %r9d
	movslq	%r9d, %rdx
	testl	%r9d, %r9d
	jg	.L934
	jmp	.L931
	.p2align 4
	.p2align 4,,10
	.p2align 3
.L932:
	addq	$1, %rax
	cmpq	%rdx, %rax
	je	.L941
.L934:
	cmpl	%r8d, 12(%rcx,%rax,4)
	jne	.L932
	imulq	$344, %rdi, %rdi
	leal	5(%rax), %edx
	cltq
	movslq	%edx, %rdx
	addq	$5, %rax
	salq	$4, %rdx
	salq	$4, %rax
	addq	%rbx, %rdx
	addq	%rdi, %rax
	movl	$1, (%rdx,%r10)
	movq	%rsi, 8(%rbx,%rax)
.L933:
	xorl	%eax, %eax
.L927:
	addq	$32, %rsp
	popq	%rbx
	popq	%rsi
	popq	%rdi
	ret
	.p2align 4,,10
	.p2align 3
.L941:
	cmpl	$16, %r9d
	je	.L930
.L931:
	imulq	$86, %rdi, %rax
	imulq	$344, %rdi, %rdi
	addq	%rdx, %rax
	movl	%r8d, 12(%rbx,%rax,4)
	leaq	5(%rdx), %rax
	salq	$4, %rax
	addq	%rdi, %rax
	movl	$1, (%rbx,%rax)
	movq	%rsi, 8(%rbx,%rax)
	addl	$1, 336(%rbx,%rdi)
	jmp	.L933
.L930:
	movl	$-1, %eax
	jmp	.L927
	.seh_endproc
	.p2align 4
	.globl	herb_container_count
	.def	herb_container_count;	.scl	2;	.type	32;	.endef
	.seh_proc	herb_container_count
herb_container_count:
	subq	$40, %rsp
	.seh_stackalloc	40
	.seh_endprologue
	call	intern
	movl	%eax, %ecx
	call	graph_find_container_by_name
	testl	%eax, %eax
	js	.L944
	cltq
	leaq	g_graph(%rip), %rdx
	imulq	$280, %rax, %rax
	movl	352532(%rdx,%rax), %eax
.L942:
	addq	$40, %rsp
	ret
.L944:
	movl	$-1, %eax
	jmp	.L942
	.seh_endproc
	.p2align 4
	.globl	herb_container_entity
	.def	herb_container_entity;	.scl	2;	.type	32;	.endef
	.seh_proc	herb_container_entity
herb_container_entity:
	pushq	%rbx
	.seh_pushreg	%rbx
	subq	$32, %rsp
	.seh_stackalloc	32
	.seh_endprologue
	movslq	%edx, %rbx
	call	intern
	movl	%eax, %ecx
	call	graph_find_container_by_name
	movl	%eax, %edx
	orl	%ebx, %edx
	js	.L948
	cltq
	leaq	g_graph(%rip), %rdx
	imulq	$280, %rax, %rcx
	cmpl	%ebx, 352532(%rdx,%rcx)
	jle	.L948
	imulq	$70, %rax, %rax
	leaq	88068(%rbx,%rax), %rax
	movl	4(%rdx,%rax,4), %eax
.L945:
	addq	$32, %rsp
	popq	%rbx
	ret
	.p2align 4,,10
	.p2align 3
.L948:
	movl	$-1, %eax
	jmp	.L945
	.seh_endproc
	.section .rdata,"dr"
.LC33:
	.ascii "?\0"
	.text
	.p2align 4
	.globl	herb_entity_name
	.def	herb_entity_name;	.scl	2;	.type	32;	.endef
	.seh_proc	herb_entity_name
herb_entity_name:
	.seh_endprologue
	leaq	.LC33(%rip), %rax
	testl	%ecx, %ecx
	js	.L949
	cmpl	%ecx, 352256+g_graph(%rip)
	jg	.L953
.L949:
	ret
	.p2align 4,,10
	.p2align 3
.L953:
	movslq	%ecx, %rcx
	leaq	g_graph(%rip), %rax
	imulq	$344, %rcx, %rcx
	movl	8(%rax,%rcx), %ecx
	jmp	str_of
	.seh_endproc
	.p2align 4
	.globl	herb_entity_prop_int
	.def	herb_entity_prop_int;	.scl	2;	.type	32;	.endef
	.seh_proc	herb_entity_prop_int
herb_entity_prop_int:
	pushq	%rsi
	.seh_pushreg	%rsi
	pushq	%rbx
	.seh_pushreg	%rbx
	subq	$40, %rsp
	.seh_stackalloc	40
	.seh_endprologue
	movq	%r8, %rbx
	testl	%ecx, %ecx
	js	.L955
	cmpl	%ecx, 352256+g_graph(%rip)
	jg	.L960
.L955:
	movq	%rbx, %rax
.L954:
	addq	$40, %rsp
	popq	%rbx
	popq	%rsi
	ret
	.p2align 4,,10
	.p2align 3
.L960:
	movl	%ecx, 64(%rsp)
	movq	%rdx, %rcx
	call	intern
	movslq	64(%rsp), %rcx
	leaq	g_graph(%rip), %r8
	imulq	$344, %rcx, %rdx
	movl	336(%r8,%rdx), %r10d
	testl	%r10d, %r10d
	jle	.L955
	imulq	$-1032, %rcx, %r11
	leaq	0(,%r8,4), %r9
	movq	%r8, %rsi
	subq	%r9, %rsi
	leaq	12(%r8,%rdx), %rdx
	xorl	%r9d, %r9d
	addq	%rsi, %r11
	jmp	.L958
	.p2align 5
	.p2align 4,,10
	.p2align 3
.L956:
	addl	$1, %r9d
	addq	$4, %rdx
	cmpl	%r10d, %r9d
	je	.L955
.L958:
	cmpl	%eax, (%rdx)
	jne	.L956
	cmpl	$1, 32(%r11,%rdx,4)
	jne	.L956
	movslq	%r9d, %rax
	imulq	$344, %rcx, %r9
	addq	$5, %rax
	salq	$4, %rax
	addq	%r9, %rax
	movq	8(%r8,%rax), %rax
	jmp	.L954
	.seh_endproc
	.p2align 4
	.globl	herb_entity_prop_str
	.def	herb_entity_prop_str;	.scl	2;	.type	32;	.endef
	.seh_proc	herb_entity_prop_str
herb_entity_prop_str:
	pushq	%rsi
	.seh_pushreg	%rsi
	pushq	%rbx
	.seh_pushreg	%rbx
	subq	$56, %rsp
	.seh_stackalloc	56
	.seh_endprologue
	testl	%ecx, %ecx
	js	.L965
	cmpl	%ecx, 352256+g_graph(%rip)
	leaq	g_graph(%rip), %rbx
	jg	.L967
.L965:
	movq	%r8, %rax
	addq	$56, %rsp
	popq	%rbx
	popq	%rsi
	ret
	.p2align 4,,10
	.p2align 3
.L967:
	movl	%ecx, 44(%rsp)
	movq	%rdx, %rcx
	movq	%r8, 32(%rsp)
	call	intern
	movslq	44(%rsp), %r10
	movq	32(%rsp), %r8
	movl	%eax, %r9d
	imulq	$344, %r10, %rax
	movl	336(%rbx,%rax), %ecx
	testl	%ecx, %ecx
	jle	.L965
	imulq	$-1032, %r10, %r11
	leaq	0(,%rbx,4), %rdx
	movq	%rbx, %rsi
	subq	%rdx, %rsi
	leaq	12(%rbx,%rax), %rax
	xorl	%edx, %edx
	addq	%rsi, %r11
	jmp	.L964
	.p2align 4
	.p2align 4,,10
	.p2align 3
.L963:
	addl	$1, %edx
	addq	$4, %rax
	cmpl	%ecx, %edx
	je	.L965
.L964:
	cmpl	%r9d, (%rax)
	jne	.L963
	cmpl	$3, 32(%r11,%rax,4)
	jne	.L963
	imulq	$344, %r10, %r10
	movslq	%edx, %rax
	addq	$5, %rax
	salq	$4, %rax
	addq	%r10, %rax
	movl	8(%rbx,%rax), %ecx
	addq	$56, %rsp
	popq	%rbx
	popq	%rsi
	jmp	str_of
	.seh_endproc
	.p2align 4
	.globl	herb_entity_location
	.def	herb_entity_location;	.scl	2;	.type	32;	.endef
	.seh_proc	herb_entity_location
herb_entity_location:
	.seh_endprologue
	testl	%ecx, %ecx
	js	.L971
	cmpl	%ecx, 352256+g_graph(%rip)
	leaq	g_graph(%rip), %rdx
	jle	.L971
	movslq	%ecx, %rcx
	movslq	567572(%rdx,%rcx,4), %rax
	testl	%eax, %eax
	js	.L972
	imulq	$280, %rax, %rax
	movl	352264(%rdx,%rax), %ecx
	jmp	str_of
	.p2align 4,,10
	.p2align 3
.L971:
	leaq	.LC33(%rip), %rax
	ret
	.p2align 4,,10
	.p2align 3
.L972:
	leaq	.LC24(%rip), %rax
	ret
	.seh_endproc
	.p2align 4
	.globl	herb_entity_total
	.def	herb_entity_total;	.scl	2;	.type	32;	.endef
	.seh_proc	herb_entity_total
herb_entity_total:
	.seh_endprologue
	movl	352256+g_graph(%rip), %eax
	ret
	.seh_endproc
	.p2align 4
	.globl	herb_arena_usage
	.def	herb_arena_usage;	.scl	2;	.type	32;	.endef
	.seh_proc	herb_arena_usage
herb_arena_usage:
	.seh_endprologue
	movq	g_arena(%rip), %rcx
	testq	%rcx, %rcx
	je	.L975
	jmp	herb_arena_used
	.p2align 4,,10
	.p2align 3
.L975:
	xorl	%eax, %eax
	ret
	.seh_endproc
	.p2align 4
	.globl	herb_arena_total
	.def	herb_arena_total;	.scl	2;	.type	32;	.endef
	.seh_proc	herb_arena_total
herb_arena_total:
	.seh_endprologue
	movq	g_arena(%rip), %rdx
	xorl	%eax, %eax
	testq	%rdx, %rdx
	je	.L976
	movq	8(%rdx), %rax
.L976:
	ret
	.seh_endproc
	.p2align 4
	.globl	herb_tension_count
	.def	herb_tension_count;	.scl	2;	.type	32;	.endef
	.seh_proc	herb_tension_count
herb_tension_count:
	.seh_endprologue
	movl	567568+g_graph(%rip), %eax
	ret
	.seh_endproc
	.section .rdata,"dr"
.LC34:
	.ascii "\0"
	.text
	.p2align 4
	.globl	herb_tension_name
	.def	herb_tension_name;	.scl	2;	.type	32;	.endef
	.seh_proc	herb_tension_name
herb_tension_name:
	.seh_endprologue
	leaq	.LC34(%rip), %rax
	testl	%ecx, %ecx
	js	.L981
	cmpl	%ecx, 567568+g_graph(%rip)
	jg	.L985
.L981:
	ret
	.p2align 4,,10
	.p2align 3
.L985:
	movslq	%ecx, %rcx
	leaq	g_graph(%rip), %rax
	imulq	$1960, %rcx, %rcx
	movl	442128(%rax,%rcx), %ecx
	jmp	str_of
	.seh_endproc
	.p2align 4
	.globl	herb_tension_priority
	.def	herb_tension_priority;	.scl	2;	.type	32;	.endef
	.seh_proc	herb_tension_priority
herb_tension_priority:
	.seh_endprologue
	xorl	%eax, %eax
	testl	%ecx, %ecx
	js	.L986
	cmpl	%ecx, 567568+g_graph(%rip)
	jle	.L986
	movslq	%ecx, %rcx
	leaq	g_graph(%rip), %rax
	imulq	$1960, %rcx, %rcx
	movl	442132(%rax,%rcx), %eax
.L986:
	ret
	.seh_endproc
	.p2align 4
	.globl	herb_tension_enabled
	.def	herb_tension_enabled;	.scl	2;	.type	32;	.endef
	.seh_proc	herb_tension_enabled
herb_tension_enabled:
	.seh_endprologue
	xorl	%eax, %eax
	testl	%ecx, %ecx
	js	.L990
	cmpl	%ecx, 567568+g_graph(%rip)
	jle	.L990
	movslq	%ecx, %rcx
	leaq	g_graph(%rip), %rax
	imulq	$1960, %rcx, %rcx
	movl	442136(%rax,%rcx), %eax
.L990:
	ret
	.seh_endproc
	.p2align 4
	.globl	herb_tension_set_enabled
	.def	herb_tension_set_enabled;	.scl	2;	.type	32;	.endef
	.seh_proc	herb_tension_set_enabled
herb_tension_set_enabled:
	.seh_endprologue
	testl	%ecx, %ecx
	js	.L994
	cmpl	%ecx, 567568+g_graph(%rip)
	jle	.L994
	movslq	%ecx, %rcx
	leaq	g_graph(%rip), %rax
	imulq	$1960, %rcx, %rcx
	testl	%edx, %edx
	setne	%dl
	movzbl	%dl, %edx
	movl	%edx, 442136(%rax,%rcx)
.L994:
	ret
	.seh_endproc
	.p2align 4
	.globl	herb_tension_owner
	.def	herb_tension_owner;	.scl	2;	.type	32;	.endef
	.seh_proc	herb_tension_owner
herb_tension_owner:
	.seh_endprologue
	testl	%ecx, %ecx
	js	.L999
	cmpl	%ecx, 567568+g_graph(%rip)
	jle	.L999
	movslq	%ecx, %rcx
	leaq	g_graph(%rip), %rax
	imulq	$1960, %rcx, %rcx
	movl	442140(%rax,%rcx), %eax
	ret
	.p2align 4,,10
	.p2align 3
.L999:
	movl	$-1, %eax
	ret
	.seh_endproc
	.p2align 4
	.globl	herb_tension_create
	.def	herb_tension_create;	.scl	2;	.type	32;	.endef
	.seh_proc	herb_tension_create
herb_tension_create:
	pushq	%r15
	.seh_pushreg	%r15
	pushq	%r14
	.seh_pushreg	%r14
	pushq	%r13
	.seh_pushreg	%r13
	pushq	%r12
	.seh_pushreg	%r12
	pushq	%rbp
	.seh_pushreg	%rbp
	pushq	%rdi
	.seh_pushreg	%rdi
	pushq	%rsi
	.seh_pushreg	%rsi
	pushq	%rbx
	.seh_pushreg	%rbx
	subq	$40, %rsp
	.seh_stackalloc	40
	.seh_endprologue
	movl	567568+g_graph(%rip), %edi
	leaq	g_graph(%rip), %rbx
	movq	%rcx, %r13
	movl	%edx, %r14d
	movl	%r8d, %r15d
	movq	%r9, %r12
	cmpl	$63, %edi
	jg	.L1005
	movslq	%edi, %rbp
	leal	1(%rdi), %eax
	movl	$1960, %r8d
	xorl	%edx, %edx
	imulq	$1960, %rbp, %rsi
	movl	%eax, 567568+g_graph(%rip)
	leaq	442128(%rbx,%rsi), %rcx
	call	herb_memset
	movq	%r13, %rcx
	call	intern
	movl	%r14d, 442132(%rbx,%rsi)
	movl	%eax, 442128(%rbx,%rsi)
	movl	$-1, %eax
	movl	$1, 442136(%rbx,%rsi)
	movl	%r15d, 442140(%rbx,%rsi)
	testq	%r12, %r12
	je	.L1002
	cmpb	$0, (%r12)
	jne	.L1011
.L1002:
	imulq	$1960, %rbp, %rbp
	leaq	1088+g_graph(%rip), %rcx
	addq	%rsi, %rcx
	movl	%eax, 442144(%rbx,%rbp)
	leaq	(%rbx,%rsi), %rax
	movq	%rax, %rdx
	.p2align 6
	.p2align 4
	.p2align 3
.L1003:
	movl	$-1, 442272(%rdx)
	addq	$136, %rdx
	movl	$-1, 442144(%rdx)
	movl	$-1, 442024(%rdx)
	cmpq	%rcx, %rdx
	jne	.L1003
	leaq	832+g_graph(%rip), %rdx
	movq	.LC22(%rip), %rcx
	addq	%rsi, %rdx
	.p2align 6
	.p2align 4
	.p2align 3
.L1004:
	movq	%rcx, 443260(%rax)
	addq	$104, %rax
	movl	$-1, 443184(%rax)
	movl	$-1, 443192(%rax)
	movl	$-1, 443204(%rax)
	movl	$-1, 443240(%rax)
	cmpq	%rdx, %rax
	jne	.L1004
	movl	$1, g_ham_dirty(%rip)
.L1000:
	movl	%edi, %eax
	addq	$40, %rsp
	popq	%rbx
	popq	%rsi
	popq	%rdi
	popq	%rbp
	popq	%r12
	popq	%r13
	popq	%r14
	popq	%r15
	ret
	.p2align 4,,10
	.p2align 3
.L1011:
	movq	%r12, %rcx
	call	intern
	movl	%eax, %ecx
	call	graph_find_container_by_name
	jmp	.L1002
.L1005:
	movl	$-1, %edi
	jmp	.L1000
	.seh_endproc
	.p2align 4
	.globl	herb_tension_match_in
	.def	herb_tension_match_in;	.scl	2;	.type	32;	.endef
	.seh_proc	herb_tension_match_in
herb_tension_match_in:
	pushq	%r13
	.seh_pushreg	%r13
	pushq	%r12
	.seh_pushreg	%r12
	pushq	%rbp
	.seh_pushreg	%rbp
	pushq	%rdi
	.seh_pushreg	%rdi
	pushq	%rsi
	.seh_pushreg	%rsi
	pushq	%rbx
	.seh_pushreg	%rbx
	subq	$40, %rsp
	.seh_stackalloc	40
	.seh_endprologue
	movq	%rdx, %rbp
	movq	%r8, %rdi
	movl	%r9d, %r13d
	testl	%ecx, %ecx
	js	.L1016
	cmpl	%ecx, 567568+g_graph(%rip)
	leaq	g_graph(%rip), %rbx
	jle	.L1016
	movslq	%ecx, %rcx
	imulq	$1960, %rcx, %r12
	movslq	443240(%rbx,%r12), %rax
	cmpl	$7, %eax
	jg	.L1016
	imulq	$136, %rax, %rsi
	leal	1(%rax), %ecx
	movl	$136, %r8d
	xorl	%edx, %edx
	movl	%ecx, 443240(%rbx,%r12)
	leaq	442152(%r12,%rsi), %rcx
	addq	%r12, %rsi
	addq	%rbx, %rcx
	call	herb_memset
	movq	%rbp, %rcx
	movl	$0, 442152(%rbx,%rsi)
	call	intern
	movq	%rdi, %rcx
	movl	%eax, 442156(%rbx,%rsi)
	call	intern
	movl	%eax, %ecx
	call	graph_find_container_by_name
	movl	%r13d, 442232(%rbx,%rsi)
	movl	$1, 442240(%rbx,%rsi)
	movl	$-1, 442272(%rbx,%rsi)
	movl	$-1, 442280(%rbx,%rsi)
	movl	%eax, 442160(%rbx,%rsi)
	xorl	%eax, %eax
.L1012:
	addq	$40, %rsp
	popq	%rbx
	popq	%rsi
	popq	%rdi
	popq	%rbp
	popq	%r12
	popq	%r13
	ret
	.p2align 4,,10
	.p2align 3
.L1016:
	movl	$-1, %eax
	jmp	.L1012
	.seh_endproc
	.p2align 4
	.globl	herb_tension_match_in_where
	.def	herb_tension_match_in_where;	.scl	2;	.type	32;	.endef
	.seh_proc	herb_tension_match_in_where
herb_tension_match_in_where:
	pushq	%rbx
	.seh_pushreg	%rbx
	subq	$32, %rsp
	.seh_stackalloc	32
	.seh_endprologue
	movslq	%ecx, %rbx
	movl	%ebx, %ecx
	call	herb_tension_match_in
	cmpl	$-1, %eax
	je	.L1017
	imulq	$1960, %rbx, %rbx
	leaq	g_graph(%rip), %rdx
	movq	80(%rsp), %rcx
	movl	443240(%rdx,%rbx), %eax
	subl	$1, %eax
	cltq
	imulq	$136, %rax, %rax
	addq	%rbx, %rax
	movq	%rcx, 442256(%rdx,%rax)
	xorl	%eax, %eax
.L1017:
	addq	$32, %rsp
	popq	%rbx
	ret
	.seh_endproc
	.p2align 4
	.globl	herb_tension_emit_set
	.def	herb_tension_emit_set;	.scl	2;	.type	32;	.endef
	.seh_proc	herb_tension_emit_set
herb_tension_emit_set:
	pushq	%r13
	.seh_pushreg	%r13
	pushq	%r12
	.seh_pushreg	%r12
	pushq	%rbp
	.seh_pushreg	%rbp
	pushq	%rdi
	.seh_pushreg	%rdi
	pushq	%rsi
	.seh_pushreg	%rsi
	pushq	%rbx
	.seh_pushreg	%rbx
	subq	$40, %rsp
	.seh_stackalloc	40
	.seh_endprologue
	movq	%rdx, %rbp
	movq	%r8, %rdi
	movq	%r9, %r13
	testl	%ecx, %ecx
	js	.L1026
	cmpl	%ecx, 567568+g_graph(%rip)
	leaq	g_graph(%rip), %r12
	jle	.L1026
	movslq	%ecx, %rcx
	imulq	$1960, %rcx, %rsi
	movslq	444080(%r12,%rsi), %rax
	cmpl	$7, %eax
	jg	.L1026
	imulq	$104, %rax, %rbx
	leal	1(%rax), %ecx
	movl	$104, %r8d
	xorl	%edx, %edx
	movl	%ecx, 444080(%r12,%rsi)
	leaq	443248(%rsi,%rbx), %rcx
	addq	%rsi, %rbx
	addq	%r12, %rcx
	call	herb_memset
	movq	%rbp, %rcx
	movl	$1, 443248(%r12,%rbx)
	call	intern
	movq	%rdi, %rcx
	movl	%eax, 443272(%r12,%rbx)
	call	intern
	movq	%r13, 443280(%r12,%rbx)
	movq	$-1, 443260(%r12,%rbx)
	movl	$-1, 443288(%r12,%rbx)
	movl	$-1, 443296(%r12,%rbx)
	movl	$-1, 443308(%r12,%rbx)
	movl	$-1, 443344(%r12,%rbx)
	movl	%eax, 443276(%r12,%rbx)
	xorl	%eax, %eax
.L1022:
	addq	$40, %rsp
	popq	%rbx
	popq	%rsi
	popq	%rdi
	popq	%rbp
	popq	%r12
	popq	%r13
	ret
	.p2align 4,,10
	.p2align 3
.L1026:
	movl	$-1, %eax
	jmp	.L1022
	.seh_endproc
	.p2align 4
	.globl	herb_tension_emit_move
	.def	herb_tension_emit_move;	.scl	2;	.type	32;	.endef
	.seh_proc	herb_tension_emit_move
herb_tension_emit_move:
	pushq	%r15
	.seh_pushreg	%r15
	pushq	%r14
	.seh_pushreg	%r14
	pushq	%r13
	.seh_pushreg	%r13
	pushq	%r12
	.seh_pushreg	%r12
	pushq	%rbp
	.seh_pushreg	%rbp
	pushq	%rdi
	.seh_pushreg	%rdi
	pushq	%rsi
	.seh_pushreg	%rsi
	pushq	%rbx
	.seh_pushreg	%rbx
	subq	$40, %rsp
	.seh_stackalloc	40
	.seh_endprologue
	movq	%rdx, %r14
	movq	%r8, %rbp
	movq	%r9, %rdi
	testl	%ecx, %ecx
	js	.L1033
	cmpl	%ecx, 567568+g_graph(%rip)
	leaq	g_graph(%rip), %rbx
	jle	.L1033
	movslq	%ecx, %r12
	imulq	$1960, %r12, %r15
	movslq	444080(%rbx,%r15), %rsi
	cmpl	$7, %esi
	jg	.L1033
	imulq	$104, %rsi, %r13
	leal	1(%rsi), %edx
	movl	$104, %r8d
	movl	%edx, 444080(%rbx,%r15)
	xorl	%edx, %edx
	leaq	443248(%r15,%r13), %rcx
	addq	%r15, %r13
	addq	%rbx, %rcx
	call	herb_memset
	movq	%r14, %rcx
	movl	$0, 443248(%rbx,%r13)
	call	intern
	movl	442120+g_graph(%rip), %ecx
	movl	%eax, %r8d
	testl	%ecx, %ecx
	jle	.L1034
	movq	%rbx, %rdx
	xorl	%eax, %eax
	jmp	.L1030
	.p2align 5
	.p2align 4,,10
	.p2align 3
.L1036:
	addl	$1, %eax
	addq	$284, %rdx
	cmpl	%ecx, %eax
	je	.L1034
.L1030:
	cmpl	423944(%rdx), %r8d
	jne	.L1036
.L1029:
	imulq	$104, %rsi, %rsi
	movq	%rbp, %rcx
	imulq	$1960, %r12, %r12
	addq	%r12, %rsi
	movl	%eax, 443252(%rbx,%rsi)
	call	intern
	movq	%rdi, %rcx
	movl	%eax, 443256(%rbx,%rsi)
	call	intern
	movl	%eax, %ecx
	call	graph_find_container_by_name
	movl	$-1, 443264(%rbx,%rsi)
	movl	$-1, 443288(%rbx,%rsi)
	movl	$-1, 443296(%rbx,%rsi)
	movl	$-1, 443308(%rbx,%rsi)
	movl	$-1, 443344(%rbx,%rsi)
	movl	%eax, 443260(%rbx,%rsi)
	xorl	%eax, %eax
.L1027:
	addq	$40, %rsp
	popq	%rbx
	popq	%rsi
	popq	%rdi
	popq	%rbp
	popq	%r12
	popq	%r13
	popq	%r14
	popq	%r15
	ret
	.p2align 4,,10
	.p2align 3
.L1034:
	movl	$-1, %eax
	jmp	.L1029
.L1033:
	movl	$-1, %eax
	jmp	.L1027
	.seh_endproc
	.p2align 4
	.globl	herb_expr_int
	.def	herb_expr_int;	.scl	2;	.type	32;	.endef
	.seh_proc	herb_expr_int
herb_expr_int:
	pushq	%rbx
	.seh_pushreg	%rbx
	subq	$48, %rsp
	.seh_stackalloc	48
	.seh_endprologue
	movslq	g_expr_count(%rip), %rax
	movq	%rcx, %rbx
	cmpl	$4095, %eax
	jg	.L1040
	leal	1(%rax), %edx
	salq	$5, %rax
	movl	$32, %r8d
	movl	%edx, g_expr_count(%rip)
	leaq	g_expr_pool(%rip), %rdx
	addq	%rdx, %rax
	xorl	%edx, %edx
	movq	%rax, %rcx
	movq	%rax, 40(%rsp)
	call	herb_memset
	movq	40(%rsp), %rax
	movl	$0, (%rax)
	movq	%rbx, 8(%rax)
	addq	$48, %rsp
	popq	%rbx
	ret
	.p2align 4,,10
	.p2align 3
.L1040:
	leaq	.LC12(%rip), %rdx
	xorl	%ecx, %ecx
	call	herb_error
	xorl	%eax, %eax
	addq	$48, %rsp
	popq	%rbx
	ret
	.seh_endproc
	.p2align 4
	.globl	herb_expr_prop
	.def	herb_expr_prop;	.scl	2;	.type	32;	.endef
	.seh_proc	herb_expr_prop
herb_expr_prop:
	pushq	%rdi
	.seh_pushreg	%rdi
	pushq	%rsi
	.seh_pushreg	%rsi
	pushq	%rbx
	.seh_pushreg	%rbx
	subq	$32, %rsp
	.seh_stackalloc	32
	.seh_endprologue
	movslq	g_expr_count(%rip), %rbx
	movq	%rcx, %rdi
	movq	%rdx, %rsi
	cmpl	$4095, %ebx
	jg	.L1044
	leal	1(%rbx), %eax
	salq	$5, %rbx
	movl	$32, %r8d
	xorl	%edx, %edx
	movl	%eax, g_expr_count(%rip)
	leaq	g_expr_pool(%rip), %rax
	addq	%rax, %rbx
	movq	%rbx, %rcx
	call	herb_memset
	movq	%rdi, %rcx
	movl	$4, (%rbx)
	call	intern
	movq	%rsi, %rcx
	movl	%eax, 8(%rbx)
	call	intern
	movl	%eax, 12(%rbx)
	movq	%rbx, %rax
	addq	$32, %rsp
	popq	%rbx
	popq	%rsi
	popq	%rdi
	ret
	.p2align 4,,10
	.p2align 3
.L1044:
	leaq	.LC12(%rip), %rdx
	xorl	%ecx, %ecx
	xorl	%ebx, %ebx
	call	herb_error
	movq	%rbx, %rax
	addq	$32, %rsp
	popq	%rbx
	popq	%rsi
	popq	%rdi
	ret
	.seh_endproc
	.p2align 4
	.globl	herb_expr_binary
	.def	herb_expr_binary;	.scl	2;	.type	32;	.endef
	.seh_proc	herb_expr_binary
herb_expr_binary:
	pushq	%rbp
	.seh_pushreg	%rbp
	pushq	%rdi
	.seh_pushreg	%rdi
	pushq	%rsi
	.seh_pushreg	%rsi
	pushq	%rbx
	.seh_pushreg	%rbx
	subq	$40, %rsp
	.seh_stackalloc	40
	.seh_endprologue
	movslq	g_expr_count(%rip), %rbx
	movq	%rcx, %rdi
	movq	%rdx, %rbp
	movq	%r8, %rsi
	cmpl	$4095, %ebx
	jg	.L1048
	leal	1(%rbx), %eax
	salq	$5, %rbx
	movl	$32, %r8d
	xorl	%edx, %edx
	movl	%eax, g_expr_count(%rip)
	leaq	g_expr_pool(%rip), %rax
	addq	%rax, %rbx
	movq	%rbx, %rcx
	call	herb_memset
	movq	%rdi, %rcx
	movl	$6, (%rbx)
	call	intern
	movq	%rbp, 16(%rbx)
	movl	%eax, 8(%rbx)
	movq	%rbx, %rax
	movq	%rsi, 24(%rbx)
	addq	$40, %rsp
	popq	%rbx
	popq	%rsi
	popq	%rdi
	popq	%rbp
	ret
	.p2align 4,,10
	.p2align 3
.L1048:
	leaq	.LC12(%rip), %rdx
	xorl	%ecx, %ecx
	xorl	%ebx, %ebx
	call	herb_error
	movq	%rbx, %rax
	addq	$40, %rsp
	popq	%rbx
	popq	%rsi
	popq	%rdi
	popq	%rbp
	ret
	.seh_endproc
	.p2align 4
	.globl	herb_remove_owner_tensions
	.def	herb_remove_owner_tensions;	.scl	2;	.type	32;	.endef
	.seh_proc	herb_remove_owner_tensions
herb_remove_owner_tensions:
	pushq	%rbp
	.seh_pushreg	%rbp
	pushq	%rdi
	.seh_pushreg	%rdi
	pushq	%rsi
	.seh_pushreg	%rsi
	pushq	%rbx
	.seh_pushreg	%rbx
	.seh_endprologue
	movl	567568+g_graph(%rip), %r11d
	movl	%ecx, %r10d
	testl	%r11d, %r11d
	jle	.L1050
	leaq	g_graph(%rip), %rdx
	xorl	%eax, %eax
	xorl	%r9d, %r9d
	xorl	%ebx, %ebx
	leaq	442128(%rdx), %rbp
	jmp	.L1054
	.p2align 4,,10
	.p2align 3
.L1051:
	cmpl	%eax, %r9d
	je	.L1053
	movslq	%r9d, %r8
	leaq	442128(%rdx), %rsi
	movl	$245, %ecx
	imulq	$1960, %r8, %r8
	leaq	(%r8,%rbp), %rdi
	rep movsq
.L1053:
	addl	$1, %eax
	addl	$1, %r9d
	addq	$1960, %rdx
	cmpl	%r11d, %eax
	je	.L1061
.L1054:
	cmpl	%r10d, 442140(%rdx)
	jne	.L1051
	addl	$1, %eax
	addl	$1, %ebx
	addq	$1960, %rdx
	cmpl	%r11d, %eax
	jne	.L1054
.L1061:
	movl	%r9d, 567568+g_graph(%rip)
	testl	%ebx, %ebx
	je	.L1049
	movl	$1, g_ham_dirty(%rip)
.L1049:
	movl	%ebx, %eax
	popq	%rbx
	popq	%rsi
	popq	%rdi
	popq	%rbp
	ret
	.p2align 4,,10
	.p2align 3
.L1050:
	movl	$0, 567568+g_graph(%rip)
	xorl	%ebx, %ebx
	movl	%ebx, %eax
	popq	%rbx
	popq	%rsi
	popq	%rdi
	popq	%rbp
	ret
	.seh_endproc
	.p2align 4
	.globl	herb_remove_tension_by_name
	.def	herb_remove_tension_by_name;	.scl	2;	.type	32;	.endef
	.seh_proc	herb_remove_tension_by_name
herb_remove_tension_by_name:
	pushq	%rbp
	.seh_pushreg	%rbp
	pushq	%rdi
	.seh_pushreg	%rdi
	pushq	%rsi
	.seh_pushreg	%rsi
	pushq	%rbx
	.seh_pushreg	%rbx
	subq	$40, %rsp
	.seh_stackalloc	40
	.seh_endprologue
	call	intern
	movl	567568+g_graph(%rip), %r10d
	movl	%eax, %r11d
	testl	%r10d, %r10d
	jle	.L1063
	leaq	g_graph(%rip), %r8
	xorl	%edx, %edx
	xorl	%ebx, %ebx
	xorl	%r9d, %r9d
	leaq	442128(%r8), %rbp
	jmp	.L1067
	.p2align 4,,10
	.p2align 3
.L1073:
	cmpl	%edx, %r9d
	je	.L1066
	movslq	%r9d, %rax
	leaq	442128(%r8), %rsi
	movl	$245, %ecx
	imulq	$1960, %rax, %rax
	leaq	(%rax,%rbp), %rdi
	rep movsq
.L1066:
	addl	$1, %edx
	addl	$1, %r9d
	addq	$1960, %r8
	cmpl	%r10d, %edx
	je	.L1079
.L1067:
	cmpl	%r11d, 442128(%r8)
	jne	.L1073
	testl	%ebx, %ebx
	jne	.L1073
	addl	$1, %edx
	movl	$1, %ebx
	addq	$1960, %r8
	cmpl	%r10d, %edx
	jne	.L1067
	.p2align 4
	.p2align 3
.L1079:
	movl	%r9d, 567568+g_graph(%rip)
	cmpl	$1, %ebx
	jne	.L1062
	movl	$1, g_ham_dirty(%rip)
.L1062:
	movl	%ebx, %eax
	addq	$40, %rsp
	popq	%rbx
	popq	%rsi
	popq	%rdi
	popq	%rbp
	ret
	.p2align 4,,10
	.p2align 3
.L1063:
	movl	$0, 567568+g_graph(%rip)
	xorl	%ebx, %ebx
	movl	%ebx, %eax
	addq	$40, %rsp
	popq	%rbx
	popq	%rsi
	popq	%rdi
	popq	%rbp
	ret
	.seh_endproc
	.p2align 4
	.globl	herb_create_container
	.def	herb_create_container;	.scl	2;	.type	32;	.endef
	.seh_proc	herb_create_container
herb_create_container:
	pushq	%r12
	.seh_pushreg	%r12
	pushq	%rbp
	.seh_pushreg	%rbp
	pushq	%rdi
	.seh_pushreg	%rdi
	pushq	%rsi
	.seh_pushreg	%rsi
	pushq	%rbx
	.seh_pushreg	%rbx
	subq	$32, %rsp
	.seh_stackalloc	32
	.seh_endprologue
	movl	423940+g_graph(%rip), %ebx
	leaq	g_graph(%rip), %r12
	movl	%edx, %ebp
	cmpl	$255, %ebx
	jg	.L1082
	movslq	%ebx, %rsi
	leal	1(%rbx), %eax
	imulq	$280, %rsi, %rsi
	movl	%eax, 423940+g_graph(%rip)
	movl	%ebx, 352260(%r12,%rsi)
	call	intern
	movl	%ebp, 352268(%r12,%rsi)
	movl	%eax, 352264(%r12,%rsi)
	movq	.LC19(%rip), %rax
	movl	$-1, 352272(%r12,%rsi)
	movq	%rax, 352532(%r12,%rsi)
.L1080:
	movl	%ebx, %eax
	addq	$32, %rsp
	popq	%rbx
	popq	%rsi
	popq	%rdi
	popq	%rbp
	popq	%r12
	ret
	.p2align 4,,10
	.p2align 3
.L1082:
	movl	$-1, %ebx
	jmp	.L1080
	.seh_endproc
	.section .rdata,"dr"
	.align 8
.LC35:
	.ascii "program fragment has non-empty infrastructure section\0"
.LC36:
	.ascii "%s.%s\0"
	.text
	.p2align 4
	.globl	herb_load_program
	.def	herb_load_program;	.scl	2;	.type	32;	.endef
	.seh_proc	herb_load_program
herb_load_program:
	pushq	%r15
	.seh_pushreg	%r15
	pushq	%r14
	.seh_pushreg	%r14
	pushq	%r13
	.seh_pushreg	%r13
	pushq	%r12
	.seh_pushreg	%r12
	pushq	%rbp
	.seh_pushreg	%rbp
	pushq	%rdi
	.seh_pushreg	%rdi
	pushq	%rsi
	.seh_pushreg	%rsi
	pushq	%rbx
	.seh_pushreg	%rbx
	subq	$424, %rsp
	.seh_stackalloc	424
	movaps	%xmm6, 368(%rsp)
	.seh_savexmm	%xmm6, 368
	movaps	%xmm7, 384(%rsp)
	.seh_savexmm	%xmm7, 384
	movaps	%xmm8, 400(%rsp)
	.seh_savexmm	%xmm8, 400
	.seh_endprologue
	movl	%r8d, 512(%rsp)
	movq	%rdx, %r10
	movq	%r9, %r12
	movq	%rcx, 80(%rsp)
	movq	%rdx, 88(%rsp)
	cmpq	$7, %rdx
	jbe	.L1084
	cmpb	$72, (%rcx)
	jne	.L1084
	cmpb	$69, 1(%rcx)
	jne	.L1084
	cmpb	$82, 2(%rcx)
	jne	.L1084
	cmpb	$66, 3(%rcx)
	jne	.L1084
	cmpb	$1, 4(%rcx)
	jne	.L1084
	movq	$8, 96(%rsp)
	movzwl	6(%rcx), %r13d
	movl	$0, g_bin_str_count(%rip)
	testw	%r13w, %r13w
	je	.L1087
	movl	$8, %eax
	xorl	%esi, %esi
	leaq	112(%rsp), %rbp
	xorl	%edi, %edi
	leaq	g_bin_str_ids(%rip), %rbx
	.p2align 4
	.p2align 3
.L1093:
	xorl	%r11d, %r11d
	cmpq	%r10, %rax
	jnb	.L1088
	movq	80(%rsp), %r9
	leaq	1(%rax), %rdx
	movq	%rdx, 96(%rsp)
	movzbl	(%r9,%rax), %r11d
	testl	%r11d, %r11d
	je	.L1088
	leal	-1(%r11), %r8d
	movq	%rbp, %rax
	addq	%rbp, %r8
	jmp	.L1092
	.p2align 6
	.p2align 4,,10
	.p2align 3
.L1347:
	movq	96(%rsp), %rdx
	addq	$1, %rax
.L1092:
	xorl	%ecx, %ecx
	cmpq	%r10, %rdx
	jnb	.L1090
	leaq	1(%rdx), %rcx
	movq	%rcx, 96(%rsp)
	movzbl	(%r9,%rdx), %ecx
.L1090:
	movb	%cl, (%rax)
	cmpq	%rax, %r8
	jne	.L1347
.L1088:
	movb	$0, 112(%rsp,%r11)
	leal	1(%rsi), %eax
	movq	%rbp, %rcx
	addl	$1, %edi
	movl	%eax, g_bin_str_count(%rip)
	call	intern
	movl	%eax, (%rbx,%rsi,4)
	cmpw	%r13w, %di
	je	.L1087
	movslq	g_bin_str_count(%rip), %rsi
	movq	88(%rsp), %r10
	movq	96(%rsp), %rax
	jmp	.L1093
.L1087:
	movl	$-1, 64(%rsp)
	testq	%r12, %r12
	je	.L1094
	cmpb	$0, (%r12)
	jne	.L1348
.L1094:
	movl	512(%rsp), %r9d
	leaq	.LC34(%rip), %r10
	testl	%r9d, %r9d
	js	.L1095
	movslq	512(%rsp), %rax
	cmpl	%eax, 352256+g_graph(%rip)
	leaq	g_graph(%rip), %rdx
	jg	.L1349
.L1095:
	movq	96(%rsp), %rax
	movq	88(%rsp), %r9
	cmpq	%r9, %rax
	jnb	.L1254
	movq	%r10, 72(%rsp)
	leaq	g_bin_str_ids(%rip), %rsi
	leaq	.L1165(%rip), %r12
	movq	%r9, %rdi
	movd	.LC37(%rip), %xmm8
	movl	$0, 52(%rsp)
	movd	512(%rsp), %xmm0
	punpckldq	%xmm0, %xmm8
	jmp	.L1239
.L1351:
	subl	$1, %edx
	cmpb	$6, %dl
	ja	.L1255
	leaq	3(%rax), %rdx
	cmpq	%rdx, %rdi
	jb	.L1259
	movzbl	2(%rcx,%rax), %r8d
	movzbl	1(%rcx,%rax), %eax
	movq	%rdx, 96(%rsp)
	sall	$8, %r8d
	orw	%ax, %r8w
	jne	.L1350
.L1260:
	movq	%rdx, %rax
	.p2align 4
	.p2align 3
.L1099:
	cmpq	%rdi, %rax
	jnb	.L1096
.L1239:
	movq	80(%rsp), %rcx
	leaq	1(%rax), %r8
	movq	%r8, 96(%rsp)
	movzbl	(%rcx,%rax), %edx
	cmpb	$-1, %dl
	je	.L1096
	cmpb	$8, %dl
	je	.L1097
	jbe	.L1351
	cmpb	$9, %dl
	jne	.L1255
	leaq	3(%rax), %rdx
	cmpq	%rdx, %rdi
	jb	.L1259
	movzbl	2(%rcx,%rax), %eax
	movzbl	(%rcx,%r8), %ecx
	movq	%rdx, 96(%rsp)
	sall	$8, %eax
	orw	%cx, %ax
	je	.L1260
	movl	52(%rsp), %edi
	subl	$1, %eax
	movq	.LC22(%rip), %xmm6
	leaq	g_graph(%rip), %r13
	movzwl	%ax, %eax
	leal	1(%rdi,%rax), %eax
	movl	%eax, 68(%rsp)
	.p2align 4
	.p2align 3
.L1238:
	movslq	567568(%r13), %r14
	cmpl	$63, %r14d
	jg	.L1346
	imulq	$1960, %r14, %rbp
	leal	1(%r14), %eax
	movl	$1960, %r8d
	xorl	%edx, %edx
	movl	%eax, 567568(%r13)
	leaq	442128(%r13,%rbp), %rcx
	call	herb_memset
	movq	96(%rsp), %rcx
	movq	88(%rsp), %rdx
	leaq	8+g_graph(%rip), %rax
	movq	%xmm8, 442128(%rax,%rbp)
	movl	64(%rsp), %eax
	leaq	2(%rcx), %r8
	movl	%eax, 442144(%r13,%rbp)
	cmpq	%r8, %rdx
	jb	.L1261
	movq	80(%rsp), %r9
	movzbl	1(%r9,%rcx), %eax
	movzbl	(%r9,%rcx), %ecx
	movq	%r8, 96(%rsp)
	sall	$8, %eax
	orl	%ecx, %eax
	cmpw	$-1, %ax
	je	.L1106
	movzwl	%ax, %eax
	cmpl	g_bin_str_count(%rip), %eax
	jge	.L1106
.L1386:
	movl	(%rsi,%rax,4), %ecx
.L1105:
	movl	512(%rsp), %r8d
	testl	%r8d, %r8d
	js	.L1107
	movq	72(%rsp), %rax
	cmpb	$0, (%rax)
	jne	.L1352
.L1107:
	imulq	$1960, %r14, %rax
	movl	%ecx, 442128(%r13,%rax)
.L1108:
	movq	96(%rsp), %rax
	xorl	%ecx, %ecx
	leaq	2(%rax), %r8
	cmpq	%r8, %rdx
	jb	.L1109
	movq	80(%rsp), %r9
	movzbl	1(%r9,%rax), %ecx
	movzbl	(%r9,%rax), %eax
	movq	%r8, 96(%rsp)
	sall	$8, %ecx
	orl	%eax, %ecx
	movq	%r8, %rax
	movswl	%cx, %ecx
.L1109:
	imulq	$1960, %r14, %r8
	leaq	0(%r13,%r8), %r15
	movl	%ecx, 442132(%r15)
	cmpq	%rdx, %rax
	jnb	.L1110
	movq	80(%rsp), %rcx
	leaq	1(%rax), %r9
	movq	%r9, 96(%rsp)
	movzbl	(%rcx,%rax), %r10d
	movl	%r10d, 444084(%r15)
	cmpq	%rdx, %r9
	jnb	.L1111
	leaq	2(%rax), %r9
	movq	%r9, 96(%rsp)
	movzbl	1(%rcx,%rax), %eax
	movl	%eax, 443240(%r15)
	testl	%eax, %eax
	je	.L1112
	movq	%rbp, 56(%rsp)
	leaq	0(%r13,%rbp), %rbx
	xorl	%edi, %edi
	movq	.LC13(%rip), %xmm7
	.p2align 4
	.p2align 3
.L1158:
	leaq	442152(%rbx), %rcx
	movl	$136, %r8d
	xorl	%edx, %edx
	call	herb_memset
	movq	96(%rsp), %rax
	movq	88(%rsp), %rcx
	movl	$-1, 442280(%rbx)
	movq	%xmm6, 442156(%rbx)
	movq	%xmm6, 442272(%rbx)
	movq	%xmm7, 442236(%rbx)
	cmpq	%rcx, %rax
	jnb	.L1113
	movq	80(%rsp), %r9
	leaq	1(%rax), %rdx
	movq	%rdx, 96(%rsp)
	movzbl	(%r9,%rax), %r8d
	cmpb	$2, %r8b
	je	.L1114
	ja	.L1115
	testb	%r8b, %r8b
	je	.L1353
	movl	$1, 442152(%rbx)
	leaq	3(%rax), %r8
	cmpq	%r8, %rcx
	jb	.L1283
	movzbl	2(%r9,%rax), %edx
	movzbl	1(%r9,%rax), %eax
	movq	%r8, 96(%rsp)
	sall	$8, %edx
	orl	%edx, %eax
	cmpw	$-1, %ax
	je	.L1284
	movzwl	%ax, %eax
	cmpl	%eax, g_bin_str_count(%rip)
	movq	%r8, %rdx
	jle	.L1285
.L1385:
	movl	(%rsi,%rax,4), %eax
.L1145:
	movl	%eax, 442156(%rbx)
	cmpq	%rcx, %rdx
	jnb	.L1146
	leaq	1(%rdx), %rax
	xorl	%r8d, %r8d
	movq	%rax, 96(%rsp)
	cmpb	$1, (%r9,%rdx)
	sete	%r8b
	movl	%r8d, 442232(%rbx)
	cmpq	%rcx, %rax
	jnb	.L1147
	leaq	2(%rdx), %r8
	movq	%r8, 96(%rsp)
	movzbl	1(%r9,%rdx), %eax
	movl	%eax, 442228(%rbx)
	testl	%eax, %eax
	je	.L1118
	xorl	%ebp, %ebp
	jmp	.L1152
	.p2align 4,,10
	.p2align 3
.L1354:
	movq	80(%rsp), %rcx
	movzbl	1(%rcx,%r8), %eax
	movzbl	(%rcx,%r8), %ecx
	movq	%rdx, 96(%rsp)
	sall	$8, %eax
	orl	%ecx, %eax
	cmpw	$-1, %ax
	je	.L1151
	movzwl	%ax, %eax
	cmpl	%eax, g_bin_str_count(%rip)
	jle	.L1151
.L1355:
	movl	(%rsi,%rax,4), %ecx
.L1150:
	call	graph_find_container_by_name
	movl	%eax, 442164(%rbx,%rbp,4)
	addq	$1, %rbp
	cmpl	%ebp, 442228(%rbx)
	jle	.L1118
	movq	96(%rsp), %r8
	movq	88(%rsp), %rcx
.L1152:
	leaq	2(%r8), %rdx
	cmpq	%rdx, %rcx
	jnb	.L1354
	xorl	%eax, %eax
	cmpl	%eax, g_bin_str_count(%rip)
	jg	.L1355
.L1151:
	movl	$-1, %ecx
	jmp	.L1150
	.p2align 4,,10
	.p2align 3
.L1353:
	movq	%rdx, %rax
.L1113:
	movl	$0, 442152(%rbx)
	leaq	2(%rax), %r8
	cmpq	%r8, %rcx
	jb	.L1264
	movq	80(%rsp), %r9
	movzbl	1(%r9,%rax), %edx
	movzbl	(%r9,%rax), %eax
	movq	%r8, 96(%rsp)
	sall	$8, %edx
	orl	%eax, %edx
	cmpw	$-1, %dx
	je	.L1265
	movzwl	%dx, %edx
	cmpl	%edx, g_bin_str_count(%rip)
	movq	%r8, %rax
	jle	.L1266
.L1376:
	movl	(%rsi,%rdx,4), %edx
.L1120:
	movl	%edx, 442156(%rbx)
	cmpq	%rcx, %rax
	jnb	.L1121
.L1377:
	movq	80(%rsp), %r8
	leaq	1(%rax), %rdx
	movq	%rdx, 96(%rsp)
	movzbl	(%r8,%rax), %r9d
	movl	%r9d, 442240(%rbx)
	cmpq	%rcx, %rdx
	jnb	.L1267
	addq	$2, %rax
	movq	%rax, 96(%rsp)
	movzbl	(%r8,%rdx), %r8d
	movl	$1, %edx
	cmpb	$1, %r8b
	je	.L1122
	movl	$2, %edx
	cmpb	$2, %r8b
	je	.L1122
	xorl	%edx, %edx
	cmpb	$3, %r8b
	sete	%dl
	leal	(%rdx,%rdx,2), %edx
.L1122:
	leaq	2(%rax), %r8
	movl	%edx, 442232(%rbx)
	cmpq	%r8, %rcx
	jb	.L1271
	movq	80(%rsp), %r9
	movzbl	1(%r9,%rax), %edx
	movzbl	(%r9,%rax), %eax
	movq	%r8, 96(%rsp)
	sall	$8, %edx
	orl	%eax, %edx
	cmpw	$-1, %dx
	je	.L1272
	movzwl	%dx, %edx
	cmpl	%edx, g_bin_str_count(%rip)
	movq	%r8, %rax
	jle	.L1273
.L1375:
	movl	(%rsi,%rdx,4), %edx
.L1124:
	movl	%edx, 442236(%rbx)
	cmpq	%rcx, %rax
	jnb	.L1125
	movq	80(%rsp), %r9
	leaq	1(%rax), %rdx
	movq	%rdx, 96(%rsp)
	movzbl	(%r9,%rax), %r8d
	testb	%r8b, %r8b
	jne	.L1126
	movq	%rdx, %rax
.L1125:
	leaq	2(%rax), %r8
	cmpq	%r8, %rcx
	jb	.L1274
	movq	80(%rsp), %rcx
	movzbl	1(%rcx,%rax), %edx
	movzbl	(%rcx,%rax), %eax
	movq	%r8, 96(%rsp)
	sall	$8, %edx
	orl	%edx, %eax
	cmpw	$-1, %ax
	je	.L1130
	movzwl	%ax, %eax
	cmpl	%eax, g_bin_str_count(%rip)
	jle	.L1130
.L1381:
	movl	(%rsi,%rax,4), %ecx
.L1129:
	call	graph_find_container_by_name
	movq	96(%rsp), %rdx
	movq	88(%rsp), %rcx
	movl	%eax, 442160(%rbx)
.L1131:
	cmpq	%rcx, %rdx
	jnb	.L1118
	leaq	1(%rdx), %rax
	movq	%rax, 96(%rsp)
	movq	80(%rsp), %rax
	cmpb	$0, (%rax,%rdx)
	jne	.L1356
.L1118:
	addl	$1, %edi
	addq	$136, %rbx
	cmpl	%edi, 443240(%r15)
	jg	.L1158
	movq	56(%rsp), %rbp
	movq	96(%rsp), %r9
	movq	88(%rsp), %rdx
.L1112:
	cmpq	%rdx, %r9
	jnb	.L1159
	imulq	$1960, %r14, %r14
	leaq	1(%r9), %rax
	movq	%rax, 96(%rsp)
	movq	80(%rsp), %rax
	movzbl	(%rax,%r9), %eax
	addq	%r13, %r14
	movl	%eax, 444080(%r14)
	testl	%eax, %eax
	je	.L1161
	leaq	443248+g_graph(%rip), %rbx
	xorl	%edi, %edi
	addq	%rbp, %rbx
	leaq	80(%rsp), %rbp
	.p2align 4
	.p2align 3
.L1236:
	movl	$104, %r8d
	xorl	%edx, %edx
	movq	%rbx, %rcx
	call	herb_memset
	movq	96(%rsp), %rax
	movq	88(%rsp), %r11
	movq	%xmm6, 12(%rbx)
	movq	%xmm6, 56(%rbx)
	movq	%xmm6, 92(%rbx)
	cmpq	%r11, %rax
	jnb	.L1162
	movq	80(%rsp), %rdx
	leaq	1(%rax), %r8
	movq	%r8, 96(%rsp)
	cmpb	$5, (%rdx,%rax)
	ja	.L1163
	movzbl	(%rdx,%rax), %ecx
	movslq	(%r12,%rcx,4), %rcx
	addq	%r12, %rcx
	jmp	*%rcx
	.section .rdata,"dr"
	.align 4
.L1165:
	.long	.L1289-.L1165
	.long	.L1169-.L1165
	.long	.L1168-.L1165
	.long	.L1167-.L1165
	.long	.L1166-.L1165
	.long	.L1164-.L1165
	.text
	.p2align 4,,10
	.p2align 3
.L1289:
	movq	%r8, %rax
.L1162:
	leaq	2(%rax), %r10
	movl	$0, (%rbx)
	cmpq	%r10, %r11
	jb	.L1357
	movq	80(%rsp), %rcx
	movzbl	1(%rcx,%rax), %edx
	movzbl	(%rcx,%rax), %ecx
	movq	%r10, 96(%rsp)
	sall	$8, %edx
	orl	%ecx, %edx
	cmpw	$-1, %dx
	je	.L1358
	movzwl	%dx, %edx
	cmpl	%edx, g_bin_str_count(%rip)
	leaq	4(%rax), %r9
	jle	.L1359
.L1171:
	movl	(%rsi,%rdx,4), %r8d
.L1175:
	movl	442120(%r13), %ecx
	testl	%ecx, %ecx
	jle	.L1293
.L1172:
	movq	%r13, %rdx
	xorl	%eax, %eax
	jmp	.L1177
	.p2align 5
	.p2align 4,,10
	.p2align 3
.L1360:
	addl	$1, %eax
	addq	$284, %rdx
	cmpl	%ecx, %eax
	je	.L1293
.L1177:
	cmpl	%r8d, 423944(%rdx)
	jne	.L1360
	movl	%eax, 4(%rbx)
	cmpq	%r9, %r11
	jb	.L1173
.L1178:
	movq	80(%rsp), %rdx
	movzbl	1(%rdx,%r10), %eax
	movzbl	(%rdx,%r10), %edx
	movq	%r9, 96(%rsp)
	sall	$8, %eax
	orl	%edx, %eax
	cmpw	$-1, %ax
	je	.L1182
	movzwl	%ax, %eax
.L1179:
	cmpl	%eax, g_bin_str_count(%rip)
	jle	.L1182
	movl	(%rsi,%rax,4), %eax
.L1181:
	movl	%eax, 8(%rbx)
	leaq	12(%rbx), %rdx
	leaq	20(%rbx), %r9
	movq	%rbp, %rcx
	leaq	16(%rbx), %r8
	call	br_to_ref
.L1163:
	addl	$1, %edi
	addq	$104, %rbx
	cmpl	%edi, 444080(%r14)
	jg	.L1236
.L1161:
	addl	$1, 52(%rsp)
	movl	68(%rsp), %edi
	cmpl	%edi, 52(%rsp)
	jne	.L1238
.L1346:
	movq	96(%rsp), %rax
	movq	88(%rsp), %rdi
	cmpq	%rdi, %rax
	jb	.L1239
.L1096:
	movl	52(%rsp), %r8d
	testl	%r8d, %r8d
	je	.L1083
	movl	$1, g_ham_dirty(%rip)
.L1083:
	movl	52(%rsp), %eax
	movaps	368(%rsp), %xmm6
	movaps	384(%rsp), %xmm7
	movaps	400(%rsp), %xmm8
	addq	$424, %rsp
	popq	%rbx
	popq	%rsi
	popq	%rdi
	popq	%rbp
	popq	%r12
	popq	%r13
	popq	%r14
	popq	%r15
	ret
	.p2align 4,,10
	.p2align 3
.L1164:
	leaq	3(%rax), %r8
	movl	$5, (%rbx)
	cmpq	%r8, %r11
	jb	.L1308
	movzbl	2(%rdx,%rax), %ecx
	movzbl	1(%rdx,%rax), %eax
	movq	%r8, 96(%rsp)
	sall	$8, %ecx
	orl	%ecx, %eax
	cmpw	$-1, %ax
	je	.L1235
	movzwl	%ax, %eax
	cmpl	%eax, g_bin_str_count(%rip)
	jle	.L1235
.L1388:
	movl	(%rsi,%rax,4), %eax
.L1234:
	movl	%eax, 88(%rbx)
	leaq	92(%rbx), %rdx
	leaq	80(%rsp), %rcx
	leaq	100(%rbx), %r9
	leaq	96(%rbx), %r8
	call	br_to_ref
	jmp	.L1163
	.p2align 4,,10
	.p2align 3
.L1166:
	leaq	3(%rax), %r10
	movl	$4, (%rbx)
	cmpq	%r10, %r11
	jb	.L1361
	movzbl	2(%rdx,%rax), %ecx
	movzbl	(%rdx,%r8), %r8d
	movq	%r10, 96(%rsp)
	sall	$8, %ecx
	orl	%r8d, %ecx
	cmpw	$-1, %cx
	je	.L1362
	movzwl	%cx, %ecx
	addq	$5, %rax
	cmpl	%ecx, g_bin_str_count(%rip)
	jle	.L1363
.L1218:
	movl	(%rsi,%rcx,4), %r15d
.L1222:
	movl	720548(%r13), %r9d
	testl	%r9d, %r9d
	jle	.L1306
.L1219:
	movq	%r13, %r8
	xorl	%ecx, %ecx
	jmp	.L1224
	.p2align 5
	.p2align 4,,10
	.p2align 3
.L1364:
	addl	$1, %ecx
	addq	$12, %r8
	cmpl	%ecx, %r9d
	je	.L1306
.L1224:
	cmpl	720356(%r8), %r15d
	jne	.L1364
	movl	%ecx, 68(%rbx)
	cmpq	%rax, %r11
	jb	.L1220
.L1382:
	movzbl	1(%rdx,%r10), %ecx
	movzbl	(%rdx,%r10), %r8d
	movq	%rax, 96(%rsp)
	sall	$8, %ecx
	orl	%r8d, %ecx
	cmpw	$-1, %cx
	je	.L1365
	movzwl	%cx, %ecx
	addq	$4, %r10
	cmpl	%ecx, g_bin_str_count(%rip)
	jle	.L1307
	movl	(%rsi,%rcx,4), %ecx
.L1226:
	movl	%ecx, 72(%rbx)
	cmpq	%r10, %r11
	jb	.L1244
	movzbl	1(%rdx,%rax), %ecx
	movzbl	(%rdx,%rax), %eax
	movq	%r10, 96(%rsp)
	sall	$8, %ecx
	orl	%ecx, %eax
	cmpw	$-1, %ax
	je	.L1231
	movzwl	%ax, %eax
	cmpl	%eax, g_bin_str_count(%rip)
	jle	.L1231
.L1383:
	movl	(%rsi,%rax,4), %eax
.L1230:
	movl	%eax, 76(%rbx)
	leaq	80(%rsp), %rcx
	call	br_expr
	movq	%rax, 80(%rbx)
	jmp	.L1163
	.p2align 4,,10
	.p2align 3
.L1167:
	leaq	3(%rax), %r10
	movl	$3, (%rbx)
	cmpq	%r10, %r11
	jb	.L1366
	movzbl	2(%rdx,%rax), %ecx
	movzbl	(%rdx,%r8), %r8d
	movq	%r10, 96(%rsp)
	sall	$8, %ecx
	orl	%r8d, %ecx
	cmpw	$-1, %cx
	je	.L1367
	movzwl	%cx, %ecx
	addq	$5, %rax
	cmpl	%ecx, g_bin_str_count(%rip)
	jle	.L1368
.L1205:
	movl	(%rsi,%rcx,4), %r15d
.L1209:
	movl	720220(%r13), %r9d
	testl	%r9d, %r9d
	jle	.L1302
.L1206:
	movq	%r13, %r8
	xorl	%ecx, %ecx
	jmp	.L1211
	.p2align 5
	.p2align 4,,10
	.p2align 3
.L1369:
	addl	$1, %ecx
	addq	$20, %r8
	cmpl	%r9d, %ecx
	je	.L1302
.L1211:
	cmpl	%r15d, 719900(%r8)
	jne	.L1369
	movl	%ecx, 48(%rbx)
	cmpq	%rax, %r11
	jb	.L1207
.L1212:
	movzbl	1(%rdx,%r10), %ecx
	movzbl	(%rdx,%r10), %edx
	movq	%rax, 96(%rsp)
	sall	$8, %ecx
	orl	%ecx, %edx
	cmpw	$-1, %dx
	je	.L1216
	movzwl	%dx, %eax
.L1213:
	cmpl	%eax, g_bin_str_count(%rip)
	jle	.L1216
	movl	(%rsi,%rax,4), %eax
.L1215:
	movl	%eax, 52(%rbx)
	leaq	56(%rbx), %rdx
	leaq	80(%rsp), %rcx
	leaq	64(%rbx), %r9
	leaq	60(%rbx), %r8
	call	br_to_ref
	jmp	.L1163
	.p2align 4,,10
	.p2align 3
.L1168:
	leaq	3(%rax), %r10
	movl	$2, (%rbx)
	cmpq	%r10, %r11
	jb	.L1370
	movzbl	2(%rdx,%rax), %ecx
	movzbl	(%rdx,%r8), %r8d
	movq	%r10, 96(%rsp)
	sall	$8, %ecx
	orl	%r8d, %ecx
	cmpw	$-1, %cx
	je	.L1371
	movzwl	%cx, %ecx
	addq	$5, %rax
	cmpl	%ecx, g_bin_str_count(%rip)
	jle	.L1372
.L1192:
	movl	(%rsi,%rcx,4), %r15d
.L1196:
	movl	720220(%r13), %r9d
	testl	%r9d, %r9d
	jle	.L1298
.L1193:
	movq	%r13, %r8
	xorl	%ecx, %ecx
	jmp	.L1198
	.p2align 5
	.p2align 4,,10
	.p2align 3
.L1373:
	addl	$1, %ecx
	addq	$20, %r8
	cmpl	%r9d, %ecx
	je	.L1298
.L1198:
	cmpl	%r15d, 719900(%r8)
	jne	.L1373
	movl	%ecx, 40(%rbx)
	cmpq	%rax, %r11
	jb	.L1194
.L1199:
	movzbl	1(%rdx,%r10), %ecx
	movzbl	(%rdx,%r10), %edx
	movq	%rax, 96(%rsp)
	sall	$8, %ecx
	orl	%ecx, %edx
	cmpw	$-1, %dx
	je	.L1203
	movzwl	%dx, %eax
.L1200:
	cmpl	%eax, g_bin_str_count(%rip)
	jle	.L1203
	movl	(%rsi,%rax,4), %eax
.L1202:
	movl	%eax, 44(%rbx)
	jmp	.L1163
	.p2align 4,,10
	.p2align 3
.L1169:
	leaq	3(%rax), %r9
	movl	$1, (%rbx)
	cmpq	%r9, %r11
	jb	.L1183
	movzbl	2(%rdx,%rax), %ecx
	movzbl	(%rdx,%r8), %r8d
	movq	%r9, 96(%rsp)
	sall	$8, %ecx
	orl	%r8d, %ecx
	cmpw	$-1, %cx
	je	.L1374
	movzwl	%cx, %ecx
	cmpl	%ecx, g_bin_str_count(%rip)
	leaq	5(%rax), %r8
	jle	.L1294
	movl	(%rsi,%rcx,4), %ecx
.L1185:
	movl	%ecx, 24(%rbx)
	cmpq	%r8, %r11
	jb	.L1242
	movzbl	4(%rdx,%rax), %eax
	movzbl	(%rdx,%r9), %edx
	movq	%r8, 96(%rsp)
	sall	$8, %eax
	orl	%edx, %eax
	cmpw	$-1, %ax
	je	.L1190
	movzwl	%ax, %eax
	cmpl	%eax, g_bin_str_count(%rip)
	jle	.L1190
.L1391:
	movl	(%rsi,%rax,4), %eax
.L1189:
	movl	%eax, 28(%rbx)
	leaq	80(%rsp), %rcx
	call	br_expr
	movq	%rax, 32(%rbx)
	jmp	.L1163
	.p2align 4,,10
	.p2align 3
.L1356:
	leaq	80(%rsp), %rcx
	call	br_expr
	movq	%rax, 442256(%rbx)
	jmp	.L1118
	.p2align 4,,10
	.p2align 3
.L1293:
	movl	$-1, %eax
	movl	%eax, 4(%rbx)
	cmpq	%r9, %r11
	jnb	.L1178
.L1173:
	xorl	%eax, %eax
	jmp	.L1179
	.p2align 4,,10
	.p2align 3
.L1115:
	cmpb	$3, %r8b
	jne	.L1118
	movl	$3, 442152(%rbx)
	leaq	80(%rsp), %rcx
	call	br_expr
	movq	%rax, 442264(%rbx)
	jmp	.L1118
	.p2align 4,,10
	.p2align 3
.L1271:
	xorl	%edx, %edx
	cmpl	%edx, g_bin_str_count(%rip)
	jg	.L1375
.L1273:
	movl	$-1, %edx
	jmp	.L1124
	.p2align 4,,10
	.p2align 3
.L1264:
	xorl	%edx, %edx
	cmpl	%edx, g_bin_str_count(%rip)
	jg	.L1376
.L1266:
	movl	$-1, %edx
	movl	%edx, 442156(%rbx)
	cmpq	%rcx, %rax
	jb	.L1377
	.p2align 4
	.p2align 3
.L1121:
	movl	$0, 442240(%rbx)
	xorl	%edx, %edx
	jmp	.L1122
	.p2align 4,,10
	.p2align 3
.L1126:
	cmpb	$1, %r8b
	je	.L1378
	cmpb	$2, %r8b
	jne	.L1131
	leaq	3(%rax), %r8
	cmpq	%r8, %rcx
	jb	.L1279
	movzbl	2(%r9,%rax), %eax
	movzbl	(%r9,%rdx), %edx
	movq	%r8, 96(%rsp)
	sall	$8, %eax
	orl	%edx, %eax
	cmpw	$-1, %ax
	je	.L1280
	movzwl	%ax, %eax
	movq	%r8, %rdx
.L1138:
	cmpl	%eax, g_bin_str_count(%rip)
	jle	.L1281
	movl	(%rsi,%rax,4), %r9d
.L1139:
	movl	720220(%r13), %r10d
	testl	%r10d, %r10d
	jle	.L1282
	movq	%r13, %r8
	xorl	%eax, %eax
	jmp	.L1141
	.p2align 5
	.p2align 4,,10
	.p2align 3
.L1379:
	addl	$1, %eax
	addq	$20, %r8
	cmpl	%r10d, %eax
	je	.L1282
.L1141:
	cmpl	%r9d, 719900(%r8)
	jne	.L1379
	movl	%eax, 442280(%rbx)
	jmp	.L1131
	.p2align 4,,10
	.p2align 3
.L1357:
	movl	g_bin_str_count(%rip), %edx
	testl	%edx, %edx
	jle	.L1380
	movq	%r10, %r9
	xorl	%edx, %edx
	movq	%rax, %r10
	jmp	.L1171
	.p2align 4,,10
	.p2align 3
.L1114:
	movl	$2, 442152(%rbx)
	leaq	3(%rax), %r8
	cmpq	%r8, %rcx
	jb	.L1287
	movzbl	2(%r9,%rax), %eax
	movzbl	(%r9,%rdx), %edx
	movq	%r8, 96(%rsp)
	sall	$8, %eax
	orl	%edx, %eax
	cmpw	$-1, %ax
	je	.L1156
	movzwl	%ax, %eax
	cmpl	g_bin_str_count(%rip), %eax
	jge	.L1156
.L1384:
	movl	(%rsi,%rax,4), %ecx
.L1155:
	call	graph_find_container_by_name
	xorl	%edx, %edx
	movl	%eax, 442248(%rbx)
	movq	96(%rsp), %rax
	cmpq	88(%rsp), %rax
	jnb	.L1157
	leaq	1(%rax), %rdx
	movq	%rdx, 96(%rsp)
	movq	80(%rsp), %rdx
	movzbl	(%rdx,%rax), %edx
.L1157:
	movl	%edx, 442244(%rbx)
	jmp	.L1118
	.p2align 4,,10
	.p2align 3
.L1274:
	xorl	%eax, %eax
	cmpl	%eax, g_bin_str_count(%rip)
	jg	.L1381
.L1130:
	movl	$-1, %ecx
	jmp	.L1129
	.p2align 4,,10
	.p2align 3
.L1302:
	movl	$-1, %ecx
	movl	%ecx, 48(%rbx)
	cmpq	%rax, %r11
	jnb	.L1212
.L1207:
	xorl	%eax, %eax
	jmp	.L1213
	.p2align 4,,10
	.p2align 3
.L1306:
	movl	$-1, %ecx
	movl	%ecx, 68(%rbx)
	cmpq	%rax, %r11
	jnb	.L1382
.L1220:
	movl	g_bin_str_count(%rip), %edx
	testl	%edx, %edx
	jle	.L1245
	movl	(%rsi), %eax
	movl	%eax, 72(%rbx)
.L1244:
	xorl	%eax, %eax
.L1395:
	cmpl	%eax, g_bin_str_count(%rip)
	jg	.L1383
.L1231:
	movl	$-1, %eax
	jmp	.L1230
	.p2align 4,,10
	.p2align 3
.L1298:
	movl	$-1, %ecx
	movl	%ecx, 40(%rbx)
	cmpq	%rax, %r11
	jnb	.L1199
.L1194:
	xorl	%eax, %eax
	jmp	.L1200
	.p2align 4,,10
	.p2align 3
.L1287:
	xorl	%eax, %eax
	cmpl	g_bin_str_count(%rip), %eax
	jl	.L1384
.L1156:
	movl	$-1, %ecx
	jmp	.L1155
	.p2align 4,,10
	.p2align 3
.L1146:
	movl	$0, 442232(%rbx)
.L1147:
	movl	$0, 442228(%rbx)
	jmp	.L1118
	.p2align 4,,10
	.p2align 3
.L1283:
	xorl	%eax, %eax
	cmpl	%eax, g_bin_str_count(%rip)
	jg	.L1385
.L1285:
	movl	$-1, %eax
	jmp	.L1145
	.p2align 4,,10
	.p2align 3
.L1110:
	movl	$0, 444084(%r15)
.L1111:
	imulq	$1960, %r14, %rax
	movl	$0, 443240(%r13,%rax)
.L1159:
	imulq	$1960, %r14, %r14
	addl	$1, 52(%rsp)
	movl	68(%rsp), %edi
	movl	$0, 444080(%r13,%r14)
	cmpl	%edi, 52(%rsp)
	jne	.L1238
	jmp	.L1346
	.p2align 4,,10
	.p2align 3
.L1261:
	xorl	%eax, %eax
	cmpl	g_bin_str_count(%rip), %eax
	jl	.L1386
.L1106:
	movl	$-1, %ecx
	jmp	.L1105
.L1366:
	movl	g_bin_str_count(%rip), %r15d
	testl	%r15d, %r15d
	jle	.L1387
	movq	%r10, %rax
	xorl	%ecx, %ecx
	movq	%r8, %r10
	jmp	.L1205
.L1308:
	xorl	%eax, %eax
	cmpl	%eax, g_bin_str_count(%rip)
	jg	.L1388
.L1235:
	movl	$-1, %eax
	jmp	.L1234
.L1361:
	movl	g_bin_str_count(%rip), %r9d
	testl	%r9d, %r9d
	jle	.L1389
	movq	%r10, %rax
	xorl	%ecx, %ecx
	movq	%r8, %r10
	jmp	.L1218
.L1370:
	movl	g_bin_str_count(%rip), %eax
	testl	%eax, %eax
	jle	.L1390
	movq	%r10, %rax
	xorl	%ecx, %ecx
	movq	%r8, %r10
	jmp	.L1192
.L1183:
	movl	g_bin_str_count(%rip), %ecx
	testl	%ecx, %ecx
	jle	.L1243
	movl	(%rsi), %eax
	movl	%eax, 24(%rbx)
.L1242:
	xorl	%eax, %eax
.L1394:
	cmpl	%eax, g_bin_str_count(%rip)
	jg	.L1391
.L1190:
	movl	$-1, %eax
	jmp	.L1189
.L1378:
	leaq	3(%rax), %r8
	cmpq	%r8, %rcx
	jb	.L1133
	movzbl	2(%r9,%rax), %r10d
	movzbl	(%r9,%rdx), %edx
	movq	%r8, 96(%rsp)
	sall	$8, %r10d
	orl	%r10d, %edx
	cmpw	$-1, %dx
	je	.L1392
	movzwl	%dx, %r10d
	cmpl	%r10d, g_bin_str_count(%rip)
	leaq	5(%rax), %rdx
	jle	.L1275
	movl	(%rsi,%r10,4), %r10d
.L1135:
	movl	%r10d, 442272(%rbx)
	cmpq	%rdx, %rcx
	jb	.L1276
	movzbl	4(%r9,%rax), %eax
	movzbl	(%r9,%r8), %r8d
	movq	%rdx, 96(%rsp)
	sall	$8, %eax
	orl	%r8d, %eax
	cmpw	$-1, %ax
	je	.L1278
	movzwl	%ax, %eax
	cmpl	%eax, g_bin_str_count(%rip)
	jle	.L1278
.L1393:
	movl	(%rsi,%rax,4), %eax
.L1137:
	movl	%eax, 442276(%rbx)
	jmp	.L1131
.L1352:
	call	str_of
	movq	72(%rsp), %r9
	movl	$128, %edx
	leaq	.LC36(%rip), %r8
	movq	%rax, 32(%rsp)
	leaq	112(%rsp), %rcx
	call	herb_snprintf
	leaq	112(%rsp), %rcx
	call	intern
	movl	%eax, %edx
	imulq	$1960, %r14, %rax
	movl	%edx, 442128(%r13,%rax)
	movq	88(%rsp), %rdx
	jmp	.L1108
.L1182:
	movl	$-1, %eax
	jmp	.L1181
.L1097:
	addq	$3, %rax
	cmpq	%rax, %rdi
	cmovb	%r8, %rax
	jmp	.L1099
.L1255:
	movq	%rdi, %rax
	jmp	.L1099
.L1359:
	movl	$-1, %r8d
	jmp	.L1175
.L1133:
	movl	g_bin_str_count(%rip), %eax
	testl	%eax, %eax
	jle	.L1246
	movl	(%rsi), %eax
	movl	%eax, 442272(%rbx)
	xorl	%eax, %eax
.L1396:
	cmpl	%eax, g_bin_str_count(%rip)
	jg	.L1393
.L1278:
	movl	$-1, %eax
	jmp	.L1137
.L1259:
	movq	%r8, %rax
	jmp	.L1099
.L1380:
	movl	442120(%r13), %ecx
	movq	%r10, %r9
	movl	$-1, %r8d
	movq	%rax, %r10
	testl	%ecx, %ecx
	jg	.L1172
	movl	$-1, 4(%rbx)
	xorl	%eax, %eax
	jmp	.L1179
	.p2align 4,,10
	.p2align 3
.L1282:
	movl	$-1, %eax
	movl	%eax, 442280(%rbx)
	jmp	.L1131
.L1203:
	movl	$-1, %eax
	jmp	.L1202
.L1216:
	movl	$-1, %eax
	jmp	.L1215
.L1279:
	xorl	%eax, %eax
	jmp	.L1138
.L1348:
	movq	%r12, %rcx
	call	intern
	movl	%eax, %ecx
	call	graph_find_container_by_name
	movl	%eax, 64(%rsp)
	jmp	.L1094
.L1358:
	leaq	4(%rax), %r9
	movl	$-1, %r8d
	jmp	.L1175
.L1294:
	movl	$-1, %ecx
	jmp	.L1185
.L1372:
	movl	$-1, %r15d
	jmp	.L1196
.L1368:
	movl	$-1, %r15d
	jmp	.L1209
.L1363:
	movl	$-1, %r15d
	jmp	.L1222
.L1272:
	movq	%r8, %rax
	movl	$-1, %edx
	jmp	.L1124
.L1265:
	movq	%r8, %rax
	movl	$-1, %edx
	jmp	.L1120
.L1307:
	movl	$-1, %ecx
	jmp	.L1226
.L1243:
	movl	$-1, 24(%rbx)
	xorl	%eax, %eax
	jmp	.L1394
.L1390:
	movl	720220(%r13), %r9d
	movq	%r10, %rax
	movl	$-1, %r15d
	movq	%r8, %r10
	testl	%r9d, %r9d
	jg	.L1193
	movl	$-1, 40(%rbx)
	xorl	%eax, %eax
	jmp	.L1200
	.p2align 4,,10
	.p2align 3
.L1389:
	movl	720548(%r13), %r9d
	movq	%r10, %rax
	movl	$-1, %r15d
	movq	%r8, %r10
	testl	%r9d, %r9d
	jg	.L1219
	movl	$-1, 68(%rbx)
	jmp	.L1220
	.p2align 4,,10
	.p2align 3
.L1387:
	movl	720220(%r13), %r9d
	movq	%r10, %rax
	movl	$-1, %r15d
	movq	%r8, %r10
	testl	%r9d, %r9d
	jg	.L1206
	movl	$-1, 48(%rbx)
	xorl	%eax, %eax
	jmp	.L1213
	.p2align 4,,10
	.p2align 3
.L1245:
	movl	$-1, 72(%rbx)
	xorl	%eax, %eax
	jmp	.L1395
.L1349:
	imulq	$344, %rax, %rax
	movl	8(%rdx,%rax), %ecx
	call	str_of
	movq	%rax, %r10
	jmp	.L1095
.L1350:
	leaq	.LC35(%rip), %rdx
	movl	$1, %ecx
	call	herb_error
.L1084:
	movl	$-1, 52(%rsp)
	jmp	.L1083
.L1275:
	movl	$-1, %r10d
	jmp	.L1135
.L1284:
	movq	%r8, %rdx
	movl	$-1, %eax
	jmp	.L1145
.L1246:
	movl	$-1, 442272(%rbx)
	xorl	%eax, %eax
	jmp	.L1396
.L1371:
	addq	$5, %rax
	movl	$-1, %r15d
	jmp	.L1196
.L1374:
	leaq	5(%rax), %r8
	movl	$-1, %ecx
	jmp	.L1185
.L1362:
	addq	$5, %rax
	movl	$-1, %r15d
	jmp	.L1222
.L1367:
	addq	$5, %rax
	movl	$-1, %r15d
	jmp	.L1209
.L1281:
	movl	$-1, %r9d
	jmp	.L1139
.L1365:
	addq	$4, %r10
	movl	$-1, %ecx
	jmp	.L1226
.L1276:
	movq	%r8, %rdx
	xorl	%eax, %eax
	jmp	.L1396
	.p2align 4,,10
	.p2align 3
.L1392:
	leaq	5(%rax), %rdx
	movl	$-1, %r10d
	jmp	.L1135
.L1254:
	movl	$0, 52(%rsp)
	jmp	.L1083
.L1280:
	movq	%r8, %rdx
	movl	$-1, %r9d
	jmp	.L1139
.L1267:
	movq	%rdx, %rax
	xorl	%edx, %edx
	jmp	.L1122
	.seh_endproc
	.p2align 4
	.globl	ham_scan
	.def	ham_scan;	.scl	2;	.type	32;	.endef
	.seh_proc	ham_scan
ham_scan:
	.seh_endprologue
	xorl	%r10d, %r10d
	testl	%ecx, %ecx
	js	.L1397
	cmpl	%ecx, 423940+g_graph(%rip)
	jle	.L1397
	movslq	%ecx, %rcx
	leaq	g_graph(%rip), %r9
	imulq	$280, %rcx, %rcx
	addq	%rcx, %r9
	movl	352532(%r9), %r10d
	cmpl	%r10d, %r8d
	cmovle	%r8d, %r10d
	testl	%r10d, %r10d
	jle	.L1397
	movslq	%r10d, %r8
	xorl	%eax, %eax
	salq	$2, %r8
	.p2align 5
	.p2align 4
	.p2align 3
.L1400:
	movl	352276(%r9,%rax), %ecx
	movl	%ecx, (%rdx,%rax)
	addq	$4, %rax
	cmpq	%r8, %rax
	jne	.L1400
.L1397:
	movl	%r10d, %eax
	ret
	.seh_endproc
	.p2align 4
	.globl	ham_eprop
	.def	ham_eprop;	.scl	2;	.type	32;	.endef
	.seh_proc	ham_eprop
ham_eprop:
	.seh_endprologue
	xorl	%eax, %eax
	testl	%ecx, %ecx
	js	.L1404
	cmpl	%ecx, 352256+g_graph(%rip)
	leaq	g_graph(%rip), %r10
	jle	.L1404
	movslq	%ecx, %r9
	imulq	$344, %r9, %r11
	leaq	(%r10,%r11), %r8
	movslq	336(%r8), %rcx
	testl	%ecx, %ecx
	jg	.L1408
	jmp	.L1404
	.p2align 4
	.p2align 4,,10
	.p2align 3
.L1406:
	addq	$1, %rax
	cmpq	%rcx, %rax
	je	.L1412
.L1408:
	cmpl	12(%r8,%rax,4), %edx
	jne	.L1406
	imulq	$344, %r9, %rcx
	leal	5(%rax), %edx
	cltq
	movslq	%edx, %rdx
	addq	$5, %rax
	salq	$4, %rdx
	salq	$4, %rax
	addq	%r10, %rdx
	addq	%rcx, %rax
	movl	(%rdx,%r11), %edx
	movq	8(%r10,%rax), %rax
	cmpl	$1, %edx
	je	.L1404
	cmpl	$2, %edx
	jne	.L1412
	movq	%rax, %xmm0
	cvttsd2siq	%xmm0, %rax
.L1404:
	ret
	.p2align 4,,10
	.p2align 3
.L1412:
	xorl	%eax, %eax
	ret
	.seh_endproc
	.p2align 4
	.globl	ham_ecnt
	.def	ham_ecnt;	.scl	2;	.type	32;	.endef
	.seh_proc	ham_ecnt
ham_ecnt:
	.seh_endprologue
	xorl	%eax, %eax
	testl	%ecx, %ecx
	js	.L1418
	cmpl	%ecx, 423940+g_graph(%rip)
	jle	.L1418
	movslq	%ecx, %rcx
	leaq	g_graph(%rip), %rax
	imulq	$280, %rcx, %rcx
	movl	352532(%rax,%rcx), %eax
.L1418:
	ret
	.seh_endproc
	.p2align 4
	.globl	ham_entity_loc
	.def	ham_entity_loc;	.scl	2;	.type	32;	.endef
	.seh_proc	ham_entity_loc
ham_entity_loc:
	.seh_endprologue
	testl	%ecx, %ecx
	js	.L1425
	cmpl	%ecx, 352256+g_graph(%rip)
	jle	.L1425
	movslq	%ecx, %rcx
	leaq	g_graph(%rip), %rax
	movl	567572(%rax,%rcx,4), %eax
	ret
	.p2align 4,,10
	.p2align 3
.L1425:
	movl	$-1, %eax
	ret
	.seh_endproc
	.p2align 4
	.globl	ham_try_move
	.def	ham_try_move;	.scl	2;	.type	32;	.endef
	.seh_proc	ham_try_move
ham_try_move:
	.seh_endprologue
	addl	$1, tm_call_count(%rip)
	jmp	try_move
	.seh_endproc
	.p2align 4
	.globl	ham_eset
	.def	ham_eset;	.scl	2;	.type	32;	.endef
	.seh_proc	ham_eset
ham_eset:
	pushq	%rsi
	.seh_pushreg	%rsi
	pushq	%rbx
	.seh_pushreg	%rbx
	subq	$56, %rsp
	.seh_stackalloc	56
	.seh_endprologue
	xorl	%eax, %eax
	movl	%ecx, %r9d
	testl	%ecx, %ecx
	js	.L1427
	cmpl	%ecx, 352256+g_graph(%rip)
	leaq	g_graph(%rip), %r11
	jle	.L1427
	movslq	%ecx, %rax
	imulq	$344, %rax, %rbx
	movq	%rax, %rsi
	leaq	(%r11,%rbx), %r10
	movslq	336(%r10), %rcx
	testl	%ecx, %ecx
	jle	.L1429
	xorl	%eax, %eax
	jmp	.L1432
	.p2align 4
	.p2align 4,,10
	.p2align 3
.L1430:
	addq	$1, %rax
	cmpq	%rcx, %rax
	je	.L1429
.L1432:
	cmpl	12(%r10,%rax,4), %edx
	jne	.L1430
	leal	5(%rax), %ecx
	movslq	%ecx, %rcx
	salq	$4, %rcx
	addq	%r11, %rcx
	cmpl	$1, (%rcx,%rbx)
	jne	.L1429
	imulq	$344, %rsi, %rcx
	cltq
	addq	$5, %rax
	salq	$4, %rax
	addq	%rax, %rcx
	xorl	%eax, %eax
	cmpq	8(%r11,%rcx), %r8
	je	.L1427
.L1429:
	movq	%r8, 40(%rsp)
	movl	%r9d, %ecx
	leaq	32(%rsp), %r8
	movq	$1, 32(%rsp)
	call	entity_set_prop
	movl	$1, %eax
.L1427:
	addq	$56, %rsp
	popq	%rbx
	popq	%rsi
	ret
	.seh_endproc
	.p2align 4
	.globl	ham_resolve_scope
	.def	ham_resolve_scope;	.scl	2;	.type	32;	.endef
	.seh_proc	ham_resolve_scope
ham_resolve_scope:
	.seh_endprologue
	jmp	get_scoped_container
	.seh_endproc
	.p2align 4
	.globl	ham_try_channel_send
	.def	ham_try_channel_send;	.scl	2;	.type	32;	.endef
	.seh_proc	ham_try_channel_send
ham_try_channel_send:
	.seh_endprologue
	jmp	do_channel_send
	.seh_endproc
	.p2align 4
	.globl	ham_try_channel_recv
	.def	ham_try_channel_recv;	.scl	2;	.type	32;	.endef
	.seh_proc	ham_try_channel_recv
ham_try_channel_recv:
	.seh_endprologue
	jmp	do_channel_receive
	.seh_endproc
	.p2align 4
	.globl	ham_intern
	.def	ham_intern;	.scl	2;	.type	32;	.endef
	.seh_proc	ham_intern
ham_intern:
	.seh_endprologue
	jmp	intern
	.seh_endproc
	.p2align 4
	.globl	ham_compile_all
	.def	ham_compile_all;	.scl	2;	.type	32;	.endef
	.seh_proc	ham_compile_all
ham_compile_all:
	pushq	%r15
	.seh_pushreg	%r15
	pushq	%r14
	.seh_pushreg	%r14
	pushq	%r13
	.seh_pushreg	%r13
	pushq	%r12
	.seh_pushreg	%r12
	pushq	%rbp
	.seh_pushreg	%rbp
	pushq	%rdi
	.seh_pushreg	%rdi
	pushq	%rsi
	.seh_pushreg	%rsi
	pushq	%rbx
	.seh_pushreg	%rbx
	subq	$440, %rsp
	.seh_stackalloc	440
	.seh_endprologue
	movl	ham_op_ids_init(%rip), %eax
	movq	%rcx, %rsi
	movl	%edx, %r14d
	movq	%r8, %rbp
	testl	%eax, %eax
	jne	.L1442
	call	ham_init_op_ids.part.0
.L1442:
	movslq	567568+g_graph(%rip), %r9
	testl	%r9d, %r9d
	jle	.L1549
	leaq	176(%rsp), %r11
	xorl	%eax, %eax
	movq	%r11, %rdx
	.p2align 4
	.p2align 4
	.p2align 3
.L1444:
	movl	%eax, (%rdx)
	addl	$1, %eax
	addq	$4, %rdx
	cmpl	%eax, %r9d
	jne	.L1444
	leaq	4(%r11), %r12
	cmpl	$1, %r9d
	je	.L1651
	movl	%r9d, 56(%rsp)
	movl	%r9d, %ebx
	movq	%r12, %r10
	leal	-1(%r9), %edi
	movq	%r11, 64(%rsp)
	movl	$1, %r8d
	leaq	g_graph(%rip), %r15
	.p2align 4
	.p2align 3
.L1448:
	cmpl	%r8d, 56(%rsp)
	jle	.L1452
	movl	%edi, %eax
	subl	%r8d, %eax
	addq	%r8, %rax
	leaq	(%r12,%rax,4), %r13
	movq	%r10, %rax
	.p2align 6
	.p2align 4
	.p2align 3
.L1451:
	movslq	-4(%r10), %rdx
	movslq	(%rax), %rcx
	movq	%rdx, %r9
	imulq	$1960, %rdx, %rdx
	movq	%rcx, %r11
	imulq	$1960, %rcx, %rcx
	movl	442132(%r15,%rdx), %edx
	cmpl	%edx, 442132(%r15,%rcx)
	jle	.L1450
	movl	%r11d, -4(%r10)
	movl	%r9d, (%rax)
.L1450:
	addq	$4, %rax
	cmpq	%r13, %rax
	jne	.L1451
.L1452:
	addq	$1, %r8
	addq	$4, %r10
	cmpq	%rbx, %r8
	jne	.L1448
	movslq	56(%rsp), %r9
	movq	64(%rsp), %r11
.L1449:
	leaq	(%r11,%r9,4), %rax
	movl	$0, 124(%rsp)
	movq	%rax, 72(%rsp)
	movl	$0, 108(%rsp)
	movq	%rbp, 528(%rsp)
	.p2align 4
	.p2align 3
.L1446:
	movslq	(%r11), %r8
	imulq	$1960, %r8, %rbx
	addq	%r15, %rbx
	movl	442136(%rbx), %eax
	testl	%eax, %eax
	je	.L1547
	movl	443240(%rbx), %eax
	testl	%eax, %eax
	jle	.L1460
	xorl	%edi, %edi
	movq	%rbx, %rbp
	movq	%r8, %r13
	jmp	.L1459
	.p2align 4,,10
	.p2align 3
.L1653:
	movq	442256(%rbx), %rcx
	testq	%rcx, %rcx
	je	.L1461
.L1647:
	call	ham_expr_compilable
	testl	%eax, %eax
	je	.L1547
.L1461:
	addl	$1, %edi
	addq	$136, %rbx
	cmpl	443240(%rbp), %edi
	jge	.L1652
.L1459:
	movl	442152(%rbx), %eax
	testl	%eax, %eax
	je	.L1653
	cmpl	$1, %eax
	je	.L1654
	cmpl	$3, %eax
	je	.L1655
	cmpl	$2, %eax
	je	.L1461
	.p2align 4
	.p2align 3
.L1547:
	movq	%r12, %r11
	cmpq	%r12, 72(%rsp)
	je	.L1616
.L1656:
	addq	$4, %r12
	jmp	.L1446
	.p2align 4,,10
	.p2align 3
.L1654:
	cmpl	$1, 442228(%rbx)
	je	.L1461
	jmp	.L1547
	.p2align 4,,10
	.p2align 3
.L1655:
	movq	442264(%rbx), %rcx
	testq	%rcx, %rcx
	jne	.L1647
	movq	%r12, %r11
	cmpq	%r12, 72(%rsp)
	jne	.L1656
.L1616:
	movq	528(%rsp), %rbp
	movl	124(%rsp), %eax
.L1443:
	testq	%rbp, %rbp
	je	.L1441
	movl	108(%rsp), %esi
	movl	%esi, 0(%rbp)
.L1441:
	addq	$440, %rsp
	popq	%rbx
	popq	%rsi
	popq	%rdi
	popq	%rbp
	popq	%r12
	popq	%r13
	popq	%r14
	popq	%r15
	ret
	.p2align 4,,10
	.p2align 3
.L1652:
	movq	%r13, %r8
.L1460:
	imulq	$1960, %r8, %rbx
	xorl	%edi, %edi
	addq	%r15, %rbx
	movl	444080(%rbx), %r13d
	movq	%rbx, %rbp
	testl	%r13d, %r13d
	jle	.L1456
	movq	%r8, %r13
	jmp	.L1468
	.p2align 4,,10
	.p2align 3
.L1469:
	subl	$2, %eax
	cmpl	$1, %eax
	ja	.L1547
.L1470:
	addl	$1, %edi
	addq	$104, %rbx
	cmpl	444080(%rbp), %edi
	jge	.L1657
.L1468:
	movl	443248(%rbx), %eax
	testl	%eax, %eax
	je	.L1470
	cmpl	$1, %eax
	jne	.L1469
	movq	443280(%rbx), %rcx
	testq	%rcx, %rcx
	je	.L1547
	call	ham_expr_compilable
	testl	%eax, %eax
	je	.L1547
	addl	$1, %edi
	addq	$104, %rbx
	cmpl	444080(%rbp), %edi
	jl	.L1468
.L1657:
	movq	%r13, %r8
.L1456:
	imulq	$1960, %r8, %r11
	movl	124(%rsp), %r10d
	movl	$0, 160(%rsp)
	addq	%r15, %r11
	movl	443240(%r11), %eax
	testl	%eax, %eax
	jle	.L1472
	movslq	%eax, %rbx
	xorl	%edx, %edx
	xorl	%r9d, %r9d
	imulq	$136, %rbx, %rbx
	addq	%r11, %rbx
	jmp	.L1482
	.p2align 5
	.p2align 4,,10
	.p2align 3
.L1473:
	addq	$136, %r11
	cmpq	%rbx, %r11
	je	.L1477
.L1482:
	movl	442156(%r11), %edi
	testl	%edi, %edi
	js	.L1473
	testl	%r9d, %r9d
	jle	.L1474
.L1478:
	leaq	128(%rsp), %rcx
	xorl	%eax, %eax
	jmp	.L1479
	.p2align 4
	.p2align 4,,10
	.p2align 3
.L1475:
	addl	$1, %eax
	addq	$4, %rcx
	cmpl	%eax, %r9d
	je	.L1658
.L1479:
	cmpl	(%rcx), %edi
	jne	.L1475
	cltq
	movl	144(%rsp,%rax,4), %ebp
	testl	%ebp, %ebp
	jns	.L1659
	cmpl	$3, %r9d
	jg	.L1480
.L1608:
	movslq	%r9d, %rax
	addq	$136, %r11
	movl	$1, %edx
	movl	%r9d, 144(%rsp,%rax,4)
	addl	$1, %r9d
	movl	%edi, 128(%rsp,%rax,4)
	cmpq	%rbx, %r11
	jne	.L1482
.L1477:
	testb	%dl, %dl
	je	.L1472
	movl	%r9d, 160(%rsp)
.L1472:
	movslq	%r10d, %rax
	movl	$255, %r11d
	leal	1(%r10), %r9d
	movb	$64, (%rsi,%rax)
	imulq	$1960, %r8, %rax
	movslq	%r9d, %r9
	leal	2(%r10), %ecx
	addq	%r15, %rax
	movl	442132(%rax), %edx
	cmpl	%r11d, %edx
	cmovg	%r11d, %edx
	movb	%dl, (%rsi,%r9)
	movl	442140(%rax), %edx
	testl	%edx, %edx
	js	.L1550
	movl	%edx, %r9d
	movzbl	%dh, %edx
.L1483:
	movslq	%ecx, %rax
	leal	4(%r10), %ecx
	movb	%r9b, (%rsi,%rax)
	leal	3(%r10), %eax
	cltq
	movb	%dl, (%rsi,%rax)
	imulq	$1960, %r8, %rax
	movl	442144(%r15,%rax), %eax
	testl	%eax, %eax
	js	.L1551
	movl	%eax, %r9d
	movzbl	%ah, %eax
.L1484:
	movslq	%ecx, %rdx
	imulq	$1960, %r8, %rbx
	movb	%r9b, (%rsi,%rdx)
	leal	5(%r10), %edx
	xorl	%r9d, %r9d
	movslq	%edx, %rdx
	movb	%al, (%rsi,%rdx)
	leal	6(%r10), %eax
	addq	%r15, %rbx
	movslq	%eax, %rdx
	leal	8(%r10), %eax
	leaq	(%rsi,%rdx), %r11
	movl	%eax, 124(%rsp)
	movw	%r9w, (%r11)
	movl	443240(%rbx), %edi
	testl	%edi, %edi
	jle	.L1516
	leaq	124(%rsp), %rax
	movl	%r10d, 56(%rsp)
	xorl	%edi, %edi
	movq	%rbx, %rbp
	movq	%rax, 64(%rsp)
	leaq	128(%rsp), %r13
	movq	%rdx, 80(%rsp)
	movq	%r11, 88(%rsp)
	movq	%r8, 96(%rsp)
	jmp	.L1515
	.p2align 4,,10
	.p2align 3
.L1662:
	movl	442272(%rbx), %ecx
	testl	%ecx, %ecx
	jns	.L1660
	movslq	124(%rsp), %r8
	movslq	442280(%rbx), %rcx
	movq	%r8, %rax
	addq	%rsi, %r8
	leal	1(%rax), %edx
	leal	3(%rax), %r11d
	addl	$2, %eax
	movslq	%edx, %rdx
	cltq
	addq	%rsi, %rdx
	addq	%rsi, %rax
	testl	%ecx, %ecx
	js	.L1496
	leaq	(%rcx,%rcx,4), %rcx
	movl	719916(%r15,%rcx,4), %ecx
	movb	$1, (%r8)
	movb	%cl, (%rdx)
	movl	%r11d, 124(%rsp)
	movb	%ch, (%rax)
.L1494:
	cmpq	$0, 442256(%rbx)
	je	.L1497
	movl	442156(%rbx), %ecx
	testl	%ecx, %ecx
	jns	.L1498
.L1641:
	movl	124(%rsp), %eax
.L1499:
	movl	442240(%rbx), %edx
	testl	%edx, %edx
	je	.L1510
	leal	1(%rax), %edx
	cltq
	movl	%edx, 124(%rsp)
	movb	$20, (%rsi,%rax)
	movl	%edx, %eax
.L1510:
	leal	-20(%r14), %edx
	cmpl	%eax, %edx
	jle	.L1630
.L1665:
	addl	$1, %edi
	addq	$136, %rbx
	cmpl	443240(%rbp), %edi
	jge	.L1661
.L1515:
	movl	442152(%rbx), %eax
	testl	%eax, %eax
	je	.L1662
	cmpl	$1, %eax
	je	.L1663
	cmpl	$2, %eax
	je	.L1664
	cmpl	$3, %eax
	je	.L1514
	movl	124(%rsp), %eax
	leal	-20(%r14), %edx
	cmpl	%eax, %edx
	jg	.L1665
	.p2align 4
	.p2align 3
.L1630:
	movl	56(%rsp), %r10d
.L1480:
	movl	%r10d, 124(%rsp)
	jmp	.L1547
	.p2align 4,,10
	.p2align 3
.L1658:
	cmpl	$4, %r9d
	jne	.L1608
	movl	%r10d, 124(%rsp)
	jmp	.L1547
	.p2align 4,,10
	.p2align 3
.L1659:
	addq	$136, %r11
	cmpq	%r11, %rbx
	je	.L1477
	movl	442156(%r11), %edi
	testl	%edi, %edi
	js	.L1473
	jmp	.L1478
	.p2align 4,,10
	.p2align 3
.L1498:
	movl	160(%rsp), %r8d
	testl	%r8d, %r8d
	jle	.L1630
	movq	%r13, %rdx
	xorl	%eax, %eax
	jmp	.L1502
	.p2align 4
	.p2align 4,,10
	.p2align 3
.L1500:
	addl	$1, %eax
	addq	$4, %rdx
	cmpl	%r8d, %eax
	je	.L1630
.L1502:
	cmpl	%ecx, (%rdx)
	jne	.L1500
	cltq
	movl	144(%rsp,%rax,4), %edx
	testl	%edx, %edx
	js	.L1630
	movslq	124(%rsp), %rcx
	movq	64(%rsp), %r8
	movq	%r13, %r9
	movq	%rcx, %rax
	movb	$16, (%rsi,%rcx)
	leal	2(%rcx), %ecx
	addl	$1, %eax
	movl	%ecx, 124(%rsp)
	cltq
	movb	%dl, (%rsi,%rax)
	movq	442256(%rbx), %rcx
	movq	%rsi, %rdx
	movl	%r14d, 32(%rsp)
	call	ham_compile_expr
	testl	%eax, %eax
	je	.L1630
	movslq	124(%rsp), %rax
	leal	1(%rax), %edx
	movb	$17, (%rsi,%rax)
	movl	%edx, 124(%rsp)
.L1497:
	movl	442156(%rbx), %ecx
	testl	%ecx, %ecx
	js	.L1641
	movl	160(%rsp), %r8d
	testl	%r8d, %r8d
	jle	.L1630
	movq	%r13, %rdx
	xorl	%eax, %eax
	jmp	.L1506
	.p2align 4
	.p2align 4,,10
	.p2align 3
.L1504:
	addl	$1, %eax
	addq	$4, %rdx
	cmpl	%r8d, %eax
	je	.L1630
.L1506:
	cmpl	(%rdx), %ecx
	jne	.L1504
	cltq
	movl	144(%rsp,%rax,4), %ecx
	testl	%ecx, %ecx
	js	.L1630
	movl	442232(%rbx), %edx
	movl	124(%rsp), %eax
	testl	%edx, %edx
	jne	.L1507
	leal	1(%rax), %edx
	movslq	%eax, %r8
	addl	$2, %eax
	movslq	%edx, %rdx
	movb	$3, (%rsi,%r8)
	movl	%eax, 124(%rsp)
	movb	%cl, (%rsi,%rdx)
	jmp	.L1499
	.p2align 4,,10
	.p2align 3
.L1660:
	movl	160(%rsp), %r8d
	testl	%r8d, %r8d
	jle	.L1490
	movq	%r13, %rdx
	jmp	.L1493
	.p2align 4
	.p2align 4,,10
	.p2align 3
.L1491:
	addl	$1, %eax
	addq	$4, %rdx
	cmpl	%eax, %r8d
	je	.L1490
.L1493:
	cmpl	(%rdx), %ecx
	jne	.L1491
	cltq
	movl	144(%rsp,%rax,4), %r8d
	testl	%r8d, %r8d
	js	.L1490
	movslq	124(%rsp), %rdx
	movb	$2, (%rsi,%rdx)
	movq	%rdx, %rax
	leal	1(%rdx), %edx
	movslq	%edx, %rdx
	leal	2(%rax), %ecx
	movb	%r8b, (%rsi,%rdx)
	movl	442276(%rbx), %edx
	movslq	%ecx, %rcx
	movb	%dl, (%rsi,%rcx)
	leal	4(%rax), %ecx
	addl	$3, %eax
	cltq
	movl	%ecx, 124(%rsp)
	movb	%dh, (%rsi,%rax)
	jmp	.L1494
	.p2align 4,,10
	.p2align 3
.L1496:
	movb	$1, (%r8)
	movl	442160(%rbx), %ecx
	movb	%cl, (%rdx)
	movl	%r11d, 124(%rsp)
	movb	%ch, (%rax)
	jmp	.L1494
	.p2align 4,,10
	.p2align 3
.L1663:
	movslq	124(%rsp), %rax
	movb	$34, (%rsi,%rax)
	movq	%rax, %rdx
	movl	442164(%rbx), %ecx
	leal	1(%rax), %eax
	cltq
	movb	%cl, (%rsi,%rax)
	leal	2(%rdx), %eax
	cltq
	movb	%ch, (%rsi,%rax)
	leal	3(%rdx), %eax
	movzwl	.LC38(%rip), %ecx
	cltq
	movb	$32, (%rsi,%rax)
	leal	4(%rdx), %eax
	cltq
	movb	$0, (%rsi,%rax)
	leal	5(%rdx), %eax
	cltq
	movb	$0, (%rsi,%rax)
	leal	6(%rdx), %eax
	cltq
	movb	$0, (%rsi,%rax)
	leal	7(%rdx), %eax
	cltq
	movb	$0, (%rsi,%rax)
	leal	8(%rdx), %eax
	cltq
	movw	%cx, (%rsi,%rax)
.L1643:
	leal	11(%rdx), %eax
	addl	$10, %edx
	movslq	%edx, %rdx
	movl	%eax, 124(%rsp)
	movb	$19, (%rsi,%rdx)
	jmp	.L1510
	.p2align 4,,10
	.p2align 3
.L1507:
	cmpl	$2, %edx
	je	.L1666
	cmpl	$3, %edx
	je	.L1667
	cmpl	$1, %edx
	jne	.L1499
	leal	1(%rax), %edx
	movslq	%eax, %r8
	addl	$2, %eax
	movslq	%edx, %rdx
	movb	$6, (%rsi,%r8)
	movl	%eax, 124(%rsp)
	movb	%cl, (%rsi,%rdx)
	jmp	.L1499
	.p2align 4,,10
	.p2align 3
.L1664:
	movslq	124(%rsp), %rax
	movb	$34, (%rsi,%rax)
	movq	%rax, %rdx
	movl	442248(%rbx), %ecx
	leal	1(%rax), %eax
	cltq
	leal	8(%rdx), %r8d
	movb	%cl, (%rsi,%rax)
	leal	2(%rdx), %eax
	movslq	%r8d, %r8
	cltq
	movb	%ch, (%rsi,%rax)
	leal	3(%rdx), %eax
	leal	9(%rdx), %ecx
	cltq
	movb	$32, (%rsi,%rax)
	leal	4(%rdx), %eax
	cltq
	movb	$0, (%rsi,%rax)
	leal	5(%rdx), %eax
	cltq
	movb	$0, (%rsi,%rax)
	leal	6(%rdx), %eax
	cltq
	movb	$0, (%rsi,%rax)
	leal	7(%rdx), %eax
	cltq
	movb	$0, (%rsi,%rax)
	cmpl	$1, 442244(%rbx)
	sbbl	%eax, %eax
	andl	$-4, %eax
	addl	$43, %eax
	movb	%al, (%rsi,%r8)
	movslq	%ecx, %rax
	movb	$18, (%rsi,%rax)
	jmp	.L1643
	.p2align 4,,10
	.p2align 3
.L1514:
	movq	442264(%rbx), %rcx
	movl	%r14d, 32(%rsp)
	movq	%r13, %r9
	movq	%rsi, %rdx
	movq	64(%rsp), %r8
	call	ham_compile_expr
	testl	%eax, %eax
	je	.L1630
	movslq	124(%rsp), %rdx
	movzwl	.LC39(%rip), %ecx
	leal	2(%rdx), %eax
	movw	%cx, (%rsi,%rdx)
	movl	%eax, 124(%rsp)
	jmp	.L1510
	.p2align 4,,10
	.p2align 3
.L1490:
	call	graph_find_entity_by_name
	testl	%eax, %eax
	js	.L1630
	movl	442276(%rbx), %edx
	movl	%eax, %ecx
	call	get_scoped_container
	movl	%eax, %edx
	testl	%eax, %eax
	js	.L1630
	movslq	124(%rsp), %rcx
	movb	$1, (%rsi,%rcx)
	movq	%rcx, %rax
	leal	1(%rcx), %ecx
	movslq	%ecx, %rcx
	movb	%dl, (%rsi,%rcx)
	leal	3(%rax), %ecx
	addl	$2, %eax
	cltq
	movl	%ecx, 124(%rsp)
	movb	%dh, (%rsi,%rax)
	jmp	.L1494
.L1666:
	movslq	%eax, %rdx
	movb	$4, (%rsi,%rdx)
.L1642:
	leal	1(%rax), %edx
	leal	2(%rax), %r8d
	movslq	%edx, %rdx
	movslq	%r8d, %r8
	movb	%cl, (%rsi,%rdx)
	leal	3(%rax), %edx
	movl	442236(%rbx), %ecx
	addl	$4, %eax
	movslq	%edx, %rdx
	movb	%cl, (%rsi,%r8)
	movl	%eax, 124(%rsp)
	movb	%ch, (%rsi,%rdx)
	jmp	.L1499
.L1551:
	movl	$-1, %eax
	movl	$-1, %r9d
	jmp	.L1484
.L1550:
	movl	$-1, %edx
	movl	$-1, %r9d
	jmp	.L1483
.L1661:
	movl	56(%rsp), %r10d
	movq	80(%rsp), %rdx
	movq	88(%rsp), %r11
	movq	96(%rsp), %r8
.L1516:
	imulq	$1960, %r8, %rbp
	addq	%r15, %rbp
	movl	444080(%rbp), %ecx
	testl	%ecx, %ecx
	jle	.L1668
	movq	%r12, 56(%rsp)
	movq	%rbp, %rbx
	xorl	%edi, %edi
	movl	%r10d, %r13d
	movq	%rdx, 88(%rsp)
	leaq	128(%rsp), %r12
	movq	%r11, 96(%rsp)
	movq	%r8, 80(%rsp)
	jmp	.L1545
	.p2align 4,,10
	.p2align 3
.L1517:
	cmpl	$1, %eax
	je	.L1669
	cmpl	$2, %eax
	je	.L1670
	cmpl	$3, %eax
	je	.L1538
	movl	124(%rsp), %eax
.L1526:
	leal	-10(%r14), %edx
	cmpl	%edx, %eax
	jge	.L1640
.L1672:
	addl	$1, %edi
	addq	$104, %rbx
	cmpl	444080(%rbp), %edi
	jge	.L1671
.L1545:
	movl	443248(%rbx), %eax
	testl	%eax, %eax
	jne	.L1517
	movl	160(%rsp), %ecx
	testl	%ecx, %ecx
	jle	.L1640
	movl	443256(%rbx), %r8d
	movq	%r12, %r11
	movq	%r12, %rdx
	jmp	.L1520
	.p2align 4
	.p2align 4,,10
	.p2align 3
.L1518:
	addl	$1, %eax
	addq	$4, %rdx
	cmpl	%ecx, %eax
	je	.L1640
.L1520:
	cmpl	(%rdx), %r8d
	jne	.L1518
	cltq
	movl	144(%rsp,%rax,4), %r8d
	testl	%r8d, %r8d
	js	.L1640
	movl	443264(%rbx), %edx
	testl	%edx, %edx
	js	.L1521
	xorl	%eax, %eax
	jmp	.L1525
	.p2align 4
	.p2align 4,,10
	.p2align 3
.L1522:
	addl	$1, %eax
	addq	$4, %r11
	cmpl	%ecx, %eax
	je	.L1524
.L1525:
	cmpl	(%r11), %edx
	jne	.L1522
	cltq
	movl	144(%rsp,%rax,4), %r10d
	testl	%r10d, %r10d
	js	.L1524
	movslq	124(%rsp), %rax
	movb	$49, (%rsi,%rax)
	movq	%rax, %rdx
	movl	443252(%rbx), %r11d
	leal	1(%rax), %eax
	cltq
	movb	%r11b, (%rsi,%rax)
	leal	2(%rdx), %eax
	movl	%r11d, %ecx
	cltq
	movb	%ch, (%rsi,%rax)
	leal	3(%rdx), %eax
	cltq
	movb	%r8b, (%rsi,%rax)
	leal	4(%rdx), %eax
	cltq
	movb	%r10b, (%rsi,%rax)
	movl	443268(%rbx), %ecx
.L1644:
	leal	5(%rdx), %eax
	cltq
	movb	%cl, (%rsi,%rax)
	leal	7(%rdx), %eax
	addl	$6, %edx
	movslq	%edx, %rdx
	movl	%eax, 124(%rsp)
	movb	%ch, (%rsi,%rdx)
	leal	-10(%r14), %edx
	cmpl	%edx, %eax
	jl	.L1672
	.p2align 4
	.p2align 3
.L1640:
	movl	%r13d, %r10d
	movq	56(%rsp), %r12
	movl	%r10d, 124(%rsp)
	jmp	.L1547
	.p2align 4,,10
	.p2align 3
.L1521:
	movl	443260(%rbx), %ecx
	movl	%r8d, 64(%rsp)
	call	graph_find_container_by_name
	movl	64(%rsp), %r8d
	testl	%eax, %eax
	movl	%eax, %r10d
	js	.L1673
.L1527:
	movslq	124(%rsp), %rax
	movb	$48, (%rsi,%rax)
	movq	%rax, %rdx
	movl	443252(%rbx), %r11d
	leal	1(%rax), %eax
	cltq
	movb	%r11b, (%rsi,%rax)
	leal	2(%rdx), %eax
	movl	%r11d, %ecx
	cltq
	movb	%ch, (%rsi,%rax)
	leal	3(%rdx), %eax
	cltq
.L1645:
	movb	%r8b, (%rsi,%rax)
	leal	4(%rdx), %eax
	movl	%r10d, %ecx
	cltq
	movb	%r10b, (%rsi,%rax)
	leal	6(%rdx), %eax
	addl	$5, %edx
	movslq	%edx, %rdx
	movl	%eax, 124(%rsp)
	movb	%ch, (%rsi,%rdx)
	jmp	.L1526
	.p2align 4,,10
	.p2align 3
.L1669:
	movl	160(%rsp), %ecx
	testl	%ecx, %ecx
	jle	.L1640
	movl	443272(%rbx), %r8d
	movq	%r12, %rdx
	xorl	%eax, %eax
	jmp	.L1533
	.p2align 4
	.p2align 4,,10
	.p2align 3
.L1531:
	addl	$1, %eax
	addq	$4, %rdx
	cmpl	%eax, %ecx
	je	.L1640
.L1533:
	cmpl	(%rdx), %r8d
	jne	.L1531
	cltq
	movl	144(%rsp,%rax,4), %r11d
	testl	%r11d, %r11d
	js	.L1640
	movq	%r12, %r9
	leaq	124(%rsp), %r8
	movq	%rsi, %rdx
	movl	%r11d, 64(%rsp)
	movq	443280(%rbx), %rcx
	movl	%r14d, 32(%rsp)
	call	ham_compile_expr
	testl	%eax, %eax
	je	.L1640
	movslq	124(%rsp), %rax
	movl	64(%rsp), %r11d
	movb	$50, (%rsi,%rax)
	movq	%rax, %rdx
	leal	1(%rax), %eax
	cltq
	movb	%r11b, (%rsi,%rax)
	leal	2(%rdx), %eax
	movl	443276(%rbx), %ecx
	cltq
	movb	%cl, (%rsi,%rax)
	leal	4(%rdx), %eax
	addl	$3, %edx
	movslq	%edx, %rdx
	movl	%eax, 124(%rsp)
	movb	%ch, (%rsi,%rdx)
	jmp	.L1526
.L1670:
	movl	160(%rsp), %ecx
	testl	%ecx, %ecx
	jle	.L1640
	movl	443292(%rbx), %r8d
	movq	%r12, %rdx
	xorl	%eax, %eax
	jmp	.L1537
	.p2align 4
	.p2align 4,,10
	.p2align 3
.L1535:
	addl	$1, %eax
	addq	$4, %rdx
	cmpl	%eax, %ecx
	je	.L1640
.L1537:
	cmpl	(%rdx), %r8d
	jne	.L1535
	cltq
	movl	144(%rsp,%rax,4), %r10d
	testl	%r10d, %r10d
	js	.L1640
	movslq	124(%rsp), %rax
	movb	$51, (%rsi,%rax)
	movq	%rax, %rdx
	movl	443288(%rbx), %r8d
	leal	1(%rax), %eax
	cltq
	movb	%r8b, (%rsi,%rax)
	leal	2(%rdx), %eax
	movl	%r8d, %ecx
	cltq
	movb	%ch, (%rsi,%rax)
	leal	4(%rdx), %eax
	addl	$3, %edx
	movslq	%edx, %rdx
	movl	%eax, 124(%rsp)
	movb	%r10b, (%rsi,%rdx)
	jmp	.L1526
.L1538:
	movl	160(%rsp), %r8d
	testl	%r8d, %r8d
	jle	.L1640
	movl	443300(%rbx), %r11d
	movq	%r12, %rcx
	movq	%r12, %rdx
	xorl	%eax, %eax
	jmp	.L1541
	.p2align 5
	.p2align 4,,10
	.p2align 3
.L1539:
	addl	$1, %eax
	addq	$4, %rdx
	cmpl	%r8d, %eax
	je	.L1640
.L1541:
	cmpl	(%rdx), %r11d
	jne	.L1539
	cltq
	movl	144(%rsp,%rax,4), %r11d
	testl	%r11d, %r11d
	js	.L1640
	movl	443308(%rbx), %edx
	testl	%edx, %edx
	js	.L1640
	xorl	%eax, %eax
	jmp	.L1544
	.p2align 4
	.p2align 4,,10
	.p2align 3
.L1542:
	addl	$1, %eax
	addq	$4, %rcx
	cmpl	%r8d, %eax
	je	.L1640
.L1544:
	cmpl	(%rcx), %edx
	jne	.L1542
	cltq
	movl	144(%rsp,%rax,4), %r10d
	testl	%r10d, %r10d
	js	.L1640
	movslq	124(%rsp), %rax
	movb	$53, (%rsi,%rax)
	movq	%rax, %rdx
	movl	443296(%rbx), %r8d
	leal	1(%rax), %eax
	cltq
	movb	%r8b, (%rsi,%rax)
	leal	2(%rdx), %eax
	movl	%r8d, %ecx
	cltq
	movb	%ch, (%rsi,%rax)
	leal	3(%rdx), %eax
	cltq
	movb	%r11b, (%rsi,%rax)
	leal	4(%rdx), %eax
	cltq
	movb	%r10b, (%rsi,%rax)
	movl	443312(%rbx), %ecx
	jmp	.L1644
.L1667:
	movslq	%eax, %rdx
	movb	$5, (%rsi,%rdx)
	jmp	.L1642
.L1474:
	movslq	%r9d, %rax
	movl	%edi, 128(%rsp,%rax,4)
	movl	%r9d, 144(%rsp,%rax,4)
	jne	.L1480
	movl	$1, %edx
	movl	$1, %r9d
	jmp	.L1473
	.p2align 4,,10
	.p2align 3
.L1524:
	movl	%edx, %ecx
	movl	%r8d, 64(%rsp)
	call	graph_find_entity_by_name
	testl	%eax, %eax
	js	.L1640
	movl	443268(%rbx), %edx
	movl	%eax, %ecx
	call	get_scoped_container
	movl	%eax, %r10d
	testl	%eax, %eax
	js	.L1640
	movslq	124(%rsp), %rax
	movl	64(%rsp), %r8d
	movb	$48, (%rsi,%rax)
	movq	%rax, %rdx
	movl	443252(%rbx), %r11d
	leal	1(%rax), %eax
	cltq
	movb	%r11b, (%rsi,%rax)
	leal	2(%rdx), %eax
	movl	%r11d, %ecx
	cltq
	movb	%ch, (%rsi,%rax)
	leal	3(%rdx), %eax
	cltq
	jmp	.L1645
.L1673:
	imulq	$1960, 80(%rsp), %rax
	movl	443240(%r15,%rax), %ecx
	testl	%ecx, %ecx
	jle	.L1640
	movq	%rbp, %rdx
	xorl	%eax, %eax
	jmp	.L1529
	.p2align 5
	.p2align 4,,10
	.p2align 3
.L1528:
	addl	$1, %eax
	addq	$136, %rdx
	cmpl	%eax, %ecx
	je	.L1640
.L1529:
	cmpl	$1, 442152(%rdx)
	jne	.L1528
	movl	443260(%rbx), %r10d
	cmpl	%r10d, 442156(%rdx)
	jne	.L1528
	imulq	$1960, 80(%rsp), %rdx
	cltq
	imulq	$136, %rax, %rax
	addq	%rdx, %rax
	movl	442164(%r15,%rax), %r10d
	testl	%r10d, %r10d
	jns	.L1527
	jmp	.L1640
	.p2align 4,,10
	.p2align 3
.L1671:
	movq	88(%rsp), %rdx
	movq	96(%rsp), %r11
	movl	%r13d, %r10d
	movq	56(%rsp), %r12
.L1546:
	leal	1(%rax), %ecx
	cltq
	addl	$1, 108(%rsp)
	movl	%ecx, 124(%rsp)
	subl	%r10d, %ecx
	movb	$65, (%rsi,%rax)
	movb	%cl, (%r11)
	movb	%ch, 1(%rsi,%rdx)
	jmp	.L1547
.L1549:
	movl	$0, 108(%rsp)
	xorl	%eax, %eax
	jmp	.L1443
.L1668:
	movl	124(%rsp), %eax
	jmp	.L1546
.L1651:
	leaq	g_graph(%rip), %r15
	jmp	.L1449
	.seh_endproc
	.p2align 4
	.globl	ham_mark_dirty
	.def	ham_mark_dirty;	.scl	2;	.type	32;	.endef
	.seh_proc	ham_mark_dirty
ham_mark_dirty:
	.seh_endprologue
	movl	$1, g_ham_dirty(%rip)
	ret
	.seh_endproc
	.p2align 4
	.globl	ham_run_ham
	.def	ham_run_ham;	.scl	2;	.type	32;	.endef
	.seh_proc	ham_run_ham
ham_run_ham:
	subq	$40, %rsp
	.seh_stackalloc	40
	.seh_endprologue
	movl	g_ham_dirty(%rip), %eax
	testl	%eax, %eax
	jne	.L1676
	movl	g_ham_bytecode_len(%rip), %edx
	testl	%edx, %edx
	jle	.L1678
.L1679:
	leaq	g_ham_bytecode(%rip), %rcx
	addq	$40, %rsp
	jmp	ham_run
	.p2align 4,,10
	.p2align 3
.L1676:
	movl	$8192, %edx
	leaq	g_ham_compiled_count(%rip), %r8
	leaq	g_ham_bytecode(%rip), %rcx
	call	ham_compile_all
	movl	$0, g_ham_dirty(%rip)
	movl	%eax, %edx
	movl	%eax, g_ham_bytecode_len(%rip)
	testl	%edx, %edx
	jg	.L1679
.L1678:
	xorl	%eax, %eax
	addq	$40, %rsp
	ret
	.seh_endproc
	.p2align 4
	.globl	ham_get_compiled_count
	.def	ham_get_compiled_count;	.scl	2;	.type	32;	.endef
	.seh_proc	ham_get_compiled_count
ham_get_compiled_count:
	.seh_endprologue
	movl	g_ham_compiled_count(%rip), %eax
	ret
	.seh_endproc
	.p2align 4
	.globl	ham_get_bytecode_len
	.def	ham_get_bytecode_len;	.scl	2;	.type	32;	.endef
	.seh_proc	ham_get_bytecode_len
ham_get_bytecode_len:
	.seh_endprologue
	movl	g_ham_bytecode_len(%rip), %eax
	ret
	.seh_endproc
.lcomm arena_storage.0,24,16
	.data
	.align 4
g_ham_dirty:
	.long	1
.lcomm g_ham_compiled_count,4,4
.lcomm g_ham_bytecode_len,4,4
.lcomm g_ham_bytecode,8192,32
.lcomm ham_id_or,4,4
.lcomm ham_id_and,4,4
.lcomm ham_id_neq,4,4
.lcomm ham_id_eq,4,4
.lcomm ham_id_lte,4,4
.lcomm ham_id_gte,4,4
.lcomm ham_id_lt,4,4
.lcomm ham_id_gt,4,4
.lcomm ham_id_mul,4,4
.lcomm ham_id_sub,4,4
.lcomm ham_id_add,4,4
.lcomm ham_op_ids_init,4,4
	.globl	tm_call_count
	.bss
	.align 4
tm_call_count:
	.space 4
.lcomm g_bin_str_count,4,4
.lcomm g_bin_str_ids,8192,32
	.globl	g_graph
	.align 32
g_graph:
	.space 720568
.lcomm g_expr_count,4,4
.lcomm g_expr_pool,131072,32
	.globl	g_string_count
	.align 4
g_string_count:
	.space 4
	.globl	g_strings
	.align 32
g_strings:
	.space 262144
.lcomm g_arena,8,8
	.section .rdata,"dr"
	.align 8
.LC13:
	.long	-1
	.long	1
	.align 8
.LC14:
	.long	-1
	.long	0
	.align 8
.LC19:
	.long	0
	.long	-1
	.align 8
.LC21:
	.long	1
	.long	-1
	.align 8
.LC22:
	.long	-1
	.long	-1
	.set	.LC37,.LC13+4
	.align 2
.LC38:
	.byte	43
	.byte	18
	.align 2
.LC39:
	.byte	18
	.byte	19
	.ident	"GCC: (MinGW-W64 x86_64-ucrt-posix-seh, built by Brecht Sanders, r5) 15.2.0"
	.def	container_add;	.scl	2;	.type	32;	.endef
	.def	str_of;	.scl	2;	.type	32;	.endef
	.def	herb_snprintf;	.scl	2;	.type	32;	.endef
	.def	intern;	.scl	2;	.type	32;	.endef
	.def	herb_memset;	.scl	2;	.type	32;	.endef
	.def	herb_error;	.scl	2;	.type	32;	.endef
	.def	graph_find_container_by_name;	.scl	2;	.type	32;	.endef
	.def	herb_memcpy;	.scl	2;	.type	32;	.endef
	.def	graph_find_entity_by_name;	.scl	2;	.type	32;	.endef
	.def	entity_set_prop;	.scl	2;	.type	32;	.endef
	.def	get_scoped_container;	.scl	2;	.type	32;	.endef
	.def	herb_arena_init;	.scl	2;	.type	32;	.endef
	.def	herb_set_error_handler;	.scl	2;	.type	32;	.endef
	.def	herb_arena_used;	.scl	2;	.type	32;	.endef
	.def	try_move;	.scl	2;	.type	32;	.endef
	.def	do_channel_send;	.scl	2;	.type	32;	.endef
	.def	do_channel_receive;	.scl	2;	.type	32;	.endef
	.def	ham_run;	.scl	2;	.type	32;	.endef
