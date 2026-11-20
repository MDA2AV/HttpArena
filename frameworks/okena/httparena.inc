; HttpArena's handlers, as an okena module (okena's src/core/modules.inc):
; assembled into the binary with `make MODULES=httparena.inc`, answering in the
; workers' event loop over HTTP/1.1, HTTP/2 and HTTP/3.
;
;   handler baseline   /baseline11, /baseline2: the sum of the query's integer
;                      values and, when there is one, of the body's integer
;   handler json       /json/{count}?m=N: the dataset's first `count` items, each
;                      with total = price * quantity * m, as {"items":[...],"count":N},
;                      written field by field for every request (compressed by
;                      okena's `compress` where the route has it)
;   handler echo       POST /echo: the request's body, as it came (okena reads
;                      it, Content-Length or chunked, and decodes the chunks)
;   handler delay      /delay/{ms}: held ms milliseconds on okena's timers (the
;                      worker goes on with others), then ms
;   handler spec       /spec, /spec/headers: the compliance route (GET, HEAD,
;                      OPTIONS, POST echo; the request's fields, one a line)
;
; The dataset is read and parsed once, by the supervisor before the workers
; start (okena_init); the workers keep its parsed items, never a rendered body.

okena_handler 'baseline', ha_baseline
okena_handler 'json', ha_json
okena_handler 'echo', ha_echo
okena_handler 'delay', ha_delay
okena_handler 'spec', ha_spec
okena_init ha_init

HA_MAX		:= 256				; items kept
HA_TAGS		:= 8				; tags an item, at most
; an item
HI_ID		:= 0				; q
HI_PRICE	:= 8				; q
HI_QTY		:= 16				; q
HI_SCORE	:= 24				; q
HI_COUNT	:= 32				; q
HI_ACTIVE	:= 40				; d
HI_NTAGS	:= 44				; d
HI_NAME		:= 48				; q: the string's bytes as JSON writes them
HI_NLEN		:= 56				; d
HI_CLEN		:= 60				; d
HI_CAT		:= 64				; q
HI_TAG		:= 72				; HA_TAGS * (q bytes, q length)
HI_SIZE		:= HI_TAG + HA_TAGS * 16
HA_FILE_MAX	:= 1 shl 20

bss
	align 8
	g_ha_items	rb HI_SIZE * HA_MAX
	g_ha_n		dd ?
	g_ha_end	dq ?			; the file's end, while it is parsed
	g_ha_file	rb HA_FILE_MAX + 8
end bss

cstring ha_env, 'HTTPARENA_DATASET='
cstring ha_default, '/data/dataset.json',0
ha_text		db 'text/plain',0
ha_json_t	db 'application/json',0
ha_octet	db 'application/octet-stream',0
cstring ha_allow, 'Allow: GET, HEAD, POST, OPTIONS',13,10
HA_DELAY_MAX	:= 1000000			; ms (the hold is in microseconds, 32 bits)

; ------------------------------------------------------------ the dataset

; the supervisor: $HTTPARENA_DATASET (or /data/dataset.json) read and parsed.
; CF when it cannot be (said).
ha_init:
	push	rbx
	push	r12
	push	r13
	mov	dword [g_ha_n],0
	lea	rdi,[ha_env]
	mov	esi,ha_env.len
	call	getenv
	test	rax,rax
	jnz	@f
	lea	rax,[ha_default]
@@:
	mov	rsi,rax
	mov	edi,-100			; AT_FDCWD
	xor	edx,edx				; O_RDONLY
	xor	r10d,r10d
	mov	eax,SYS_openat
	syscall
	test	eax,eax
	js	.cannot
	mov	ebx,eax
	xor	r12d,r12d			; read so far
.read:
	mov	edi,ebx
	lea	rsi,[g_ha_file+r12]
	mov	edx,HA_FILE_MAX
	sub	edx,r12d
	jz	.read_done
	mov	eax,SYS_read
	syscall
	test	rax,rax
	js	.close_cannot
	jz	.read_done
	add	r12d,eax
	jmp	.read
.read_done:
	mov	edi,ebx
	mov	eax,SYS_close
	syscall
	lea	rsi,[g_ha_file]
	lea	rax,[rsi+r12]
	mov	[g_ha_end],rax
	; [ {item}, {item}, ... ]
	call	ha_ws
	call	ha_byte
	cmp	al,'['
	jne	.bad
.item:
	call	ha_ws
	cmp	rsi,[g_ha_end]
	jae	.bad
	cmp	byte [rsi],']'
	je	.done
	cmp	byte [rsi],','
	jne	@f
	inc	rsi
	jmp	.item
@@:
	mov	eax,[g_ha_n]
	cmp	eax,HA_MAX
	jae	.done
	imul	rdi,rax,HI_SIZE
	lea	rdi,[g_ha_items+rdi]
	call	ha_item
	jc	.bad
	inc	dword [g_ha_n]
	jmp	.item
.done:
	cmp	dword [g_ha_n],0
	je	.bad
	clc
	jmp	.out
.close_cannot:
	mov	edi,ebx
	mov	eax,SYS_close
	syscall
.cannot:
	call	log_begin
	out_lit 'httparena: cannot read the dataset (HTTPARENA_DATASET, or /data/dataset.json)'
	call	log_end
	stc
	jmp	.out
.bad:
	call	log_begin
	out_lit 'httparena: the dataset is not a JSON array of items'
	call	log_end
	stc
.out:
	pop	r13
	pop	r12
	pop	rbx
	ret

; rsi at an object, rdi = an item: its fields read. rsi = after it. CF: not one.
ha_item:
	push	rbx
	mov	rbx,rdi
	push	rdi
	mov	ecx,HI_SIZE
	xor	eax,eax
	rep	stosb
	pop	rdi
	call	ha_ws
	call	ha_byte
	cmp	al,'{'
	jne	.no
.field:
	call	ha_ws
	call	ha_byte
	cmp	al,'}'
	je	.yes
	cmp	al,','
	je	.field
	cmp	al,'"'
	jne	.no
	call	ha_str_rest			; rdi/ecx = the key
	jc	.no
	call	ha_ws
	call	ha_byte
	cmp	al,':'
	jne	.no
	call	ha_ws
	; which key
	cmp	ecx,2
	jne	@f
	cmp	word [rdi],'id'
	jne	.skip
	call	ha_int
	jc	.no
	mov	[rbx+HI_ID],rax
	jmp	.field
@@:
	cmp	ecx,4
	jne	@f
	cmp	dword [rdi],'name'
	jne	.skip_tags
	call	ha_str
	jc	.no
	mov	[rbx+HI_NAME],rdi
	mov	[rbx+HI_NLEN],ecx
	jmp	.field
.skip_tags:
	cmp	dword [rdi],'tags'
	jne	.skip
	call	ha_tags
	jc	.no
	jmp	.field
@@:
	cmp	ecx,8
	jne	@f
	mov	rax,[rdi]
	mov	rdx,'category'
	cmp	rax,rdx
	je	.category
	mov	rdx,'quantity'
	cmp	rax,rdx
	jne	.skip
	call	ha_int
	jc	.no
	mov	[rbx+HI_QTY],rax
	jmp	.field
.category:
	call	ha_str
	jc	.no
	mov	[rbx+HI_CAT],rdi
	mov	[rbx+HI_CLEN],ecx
	jmp	.field
@@:
	cmp	ecx,5
	jne	@f
	cmp	dword [rdi],'pric'
	jne	.skip
	cmp	byte [rdi+4],'e'
	jne	.skip
	call	ha_int
	jc	.no
	mov	[rbx+HI_PRICE],rax
	jmp	.field
@@:
	cmp	ecx,6
	jne	.skip
	cmp	dword [rdi],'acti'
	jne	.rating
	cmp	word [rdi+4],'ve'
	jne	.skip
	call	ha_ws
	cmp	rsi,[g_ha_end]
	jae	.no
	xor	eax,eax
	cmp	byte [rsi],'t'
	sete	al
	mov	[rbx+HI_ACTIVE],eax
	call	ha_skip
	jc	.no
	jmp	.field
.rating:
	cmp	dword [rdi],'rati'
	jne	.skip
	cmp	word [rdi+4],'ng'
	jne	.skip
	call	ha_rating
	jc	.no
	jmp	.field
.skip:
	call	ha_skip
	jc	.no
	jmp	.field
.yes:
	pop	rbx
	clc
	ret
.no:
	pop	rbx
	stc
	ret

; rsi at ["a","b"], rbx = the item: its tags
ha_tags:
	call	ha_byte
	cmp	al,'['
	jne	.no
.tag:
	call	ha_ws
	call	ha_byte
	cmp	al,']'
	je	.yes
	cmp	al,','
	je	.tag
	cmp	al,'"'
	jne	.no
	call	ha_str_rest
	jc	.no
	mov	eax,[rbx+HI_NTAGS]
	cmp	eax,HA_TAGS
	jae	.tag
	shl	eax,4
	mov	[rbx+HI_TAG+rax],rdi
	mov	[rbx+HI_TAG+rax+8],rcx
	inc	dword [rbx+HI_NTAGS]
	jmp	.tag
.yes:
	clc
	ret
.no:
	stc
	ret

; rsi at {"score":N,"count":N}, rbx = the item
ha_rating:
	call	ha_byte
	cmp	al,'{'
	jne	.no
.field:
	call	ha_ws
	call	ha_byte
	cmp	al,'}'
	je	.yes
	cmp	al,','
	je	.field
	cmp	al,'"'
	jne	.no
	call	ha_str_rest
	jc	.no
	call	ha_ws
	call	ha_byte
	cmp	al,':'
	jne	.no
	call	ha_ws
	cmp	ecx,5
	jne	.skip
	cmp	dword [rdi],'scor'
	je	.score
	cmp	dword [rdi],'coun'
	jne	.skip
	call	ha_int
	jc	.no
	mov	[rbx+HI_COUNT],rax
	jmp	.field
.score:
	call	ha_int
	jc	.no
	mov	[rbx+HI_SCORE],rax
	jmp	.field
.skip:
	call	ha_skip
	jc	.no
	jmp	.field
.yes:
	clc
	ret
.no:
	stc
	ret

; rsi: blanks skipped. Keeps all but rsi.
ha_ws:
	cmp	rsi,[g_ha_end]
	jae	.out
	cmp	byte [rsi],' '
	ja	.out
	inc	rsi
	jmp	ha_ws
.out:
	ret

; al = the byte at rsi (0 at the end), rsi past it
ha_byte:
	xor	eax,eax
	cmp	rsi,[g_ha_end]
	jae	.out
	lodsb
.out:
	ret

; rsi at a string: rdi/ecx = its bytes, escapes as written (valid in JSON as
; they are). CF: not one.
ha_str:
	call	ha_byte
	cmp	al,'"'
	jne	ha_str_rest.no
; rsi past its opening quote
ha_str_rest:
	mov	rdi,rsi
.c:
	cmp	rsi,[g_ha_end]
	jae	.no
	lodsb
	cmp	al,'\'
	jne	@f
	inc	rsi
	jmp	.c
@@:
	cmp	al,'"'
	jne	.c
	lea	rcx,[rsi-1]
	sub	rcx,rdi
	clc
	ret
.no:
	stc
	ret

; rsi at an integer: rax = it. CF: not one.
ha_int:
	xor	eax,eax
	xor	edx,edx				; negative
	xor	ecx,ecx				; digits
	cmp	rsi,[g_ha_end]
	jae	.no
	cmp	byte [rsi],'-'
	jne	.d
	inc	edx
	inc	rsi
.d:
	cmp	rsi,[g_ha_end]
	jae	.end
	movzx	r8d,byte [rsi]
	sub	r8d,'0'
	cmp	r8d,9
	ja	.end
	imul	rax,rax,10
	add	rax,r8
	inc	rsi
	inc	ecx
	jmp	.d
.end:
	test	ecx,ecx
	jz	.no
	test	edx,edx
	jz	@f
	neg	rax
@@:
	clc
	ret
.no:
	stc
	ret

; rsi at any value: past it. CF: not one.
ha_skip:
	push	rbx
	xor	ebx,ebx				; depth
.v:
	cmp	rsi,[g_ha_end]
	jae	.no
	lodsb
	cmp	al,'"'
	jne	@f
	push	rdi
	push	rcx
	call	ha_str_rest
	pop	rcx
	pop	rdi
	jc	.no
	jmp	.next
@@:
	cmp	al,'['
	je	.in
	cmp	al,'{'
	je	.in
	cmp	al,']'
	je	.out_
	cmp	al,'}'
	je	.out_
	; a number, true, false, null: up to , ] } or a blank
.word:
	cmp	rsi,[g_ha_end]
	jae	.next
	mov	al,[rsi]
	cmp	al,','
	je	.next
	cmp	al,']'
	je	.next
	cmp	al,'}'
	je	.next
	cmp	al,' '
	jbe	.next
	inc	rsi
	jmp	.word
.in:
	inc	ebx
	jmp	.v
.out_:
	dec	ebx
	js	.no
.next:
	test	ebx,ebx
	jnz	.v
	pop	rbx
	clc
	ret
.no:
	pop	rbx
	stc
	ret

; ------------------------------------------------------------ the handlers

; rsi/ecx = text: rax = the integer at its start (signed), CF when none
ha_atoi:
	xor	eax,eax
	xor	edx,edx
	xor	r8d,r8d				; digits
	test	ecx,ecx
	jz	.no
	cmp	byte [rsi],'-'
	jne	.d
	inc	edx
	inc	rsi
	dec	ecx
.d:
	test	ecx,ecx
	jz	.end
	movzx	r9d,byte [rsi]
	sub	r9d,'0'
	cmp	r9d,9
	ja	.end
	imul	rax,rax,10
	add	rax,r9
	inc	rsi
	dec	ecx
	inc	r8d
	jmp	.d
.end:
	test	r8d,r8d
	jz	.no
	test	edx,edx
	jz	@f
	neg	rax
@@:
	clc
	ret
.no:
	stc
	ret

; rdi = out, rax = a signed integer: written, rdi after. Keeps r8-r15.
ha_itoa:
	test	rax,rax
	jns	@f
	mov	byte [rdi],'-'
	inc	rdi
	neg	rax
@@:
	; the dataset's numbers are small: up to four digits from the pair table,
	; no call (rax, rcx, rdx clobbered)
	cmp	rax,10
	jb	.d1
	cmp	rax,100
	jb	.d2
	cmp	rax,10000
	jae	fmt_u64
	; 100..9999: rax / 100 by a multiply (exact below 2^16: 5243 / 2^19)
	imul	ecx,eax,5243
	shr	ecx,19				; the hundreds
	imul	edx,ecx,100
	sub	eax,edx				; the rest, 0..99
	movzx	edx,word [fmt_d2+rax*2]
	cmp	ecx,10
	jb	.d3
	movzx	eax,word [fmt_d2+rcx*2]
	mov	[rdi],ax
	mov	[rdi+2],dx
	add	rdi,4
	ret
.d3:
	add	cl,'0'
	mov	[rdi],cl
	mov	[rdi+1],dx
	add	rdi,3
	ret
.d2:
	movzx	eax,word [fmt_d2+rax*2]
	mov	[rdi],ax
	add	rdi,2
	ret
.d1:
	add	al,'0'
	mov	[rdi],al
	inc	rdi
	ret

; the query (after '?'): r10 = its start, r11d = its length, or 0 none
macro ha_query
	local find, none, done
	mov	r10,[g_hm+HM_TARGET]
	mov	r11d,[g_hm+HM_TLEN]
	mov	eax,[g_hm+HM_PLEN]
	sub	r11d,eax
	jbe	none
	lea	r10,[r10+rax+1]			; past '?'
	dec	r11d
	jmp	done
none:
	xor	r11d,r11d
done:
end macro

; `handler baseline`: the query's integer values and the body's, summed
ha_baseline:
	push	rbx
	push	r12
	mov	rbx,rdi				; out
	mov	r12,rdx				; the body
	push	rcx
	xor	edi,edi				; the sum (rdi, signed)
	ha_query
.param:
	test	r11d,r11d
	jz	.body
	; up to '=' then the value up to '&'
	cmp	byte [r10],'='
	je	.value
	cmp	byte [r10],'&'
	je	.amp
	inc	r10
	dec	r11d
	jmp	.param
.value:
	inc	r10
	dec	r11d
	mov	rsi,r10
	mov	ecx,r11d
	push	rdi
	call	ha_atoi
	pop	rdi
	jc	.param
	add	rdi,rax
	jmp	.param
.amp:
	inc	r10
	dec	r11d
	jmp	.param
.body:
	pop	rcx
	test	ecx,ecx
	jz	.out
	mov	rsi,r12
@@:
	test	ecx,ecx				; (blanks before it)
	jz	.out
	cmp	byte [rsi],' '
	ja	@f
	inc	rsi
	dec	ecx
	jmp	@b
@@:
	push	rdi
	call	ha_atoi
	pop	rdi
	jc	.out
	add	rdi,rax
.out:
	mov	rax,rdi
	mov	rdi,rbx
	call	ha_itoa
	mov	rdx,rdi
	sub	rdx,rbx
	mov	eax,200
	lea	rsi,[ha_text]
	xor	ecx,ecx				; (in the out buffer)
	pop	r12
	pop	rbx
	ret

; `handler json`: /json/{count}?m=N
ha_json:
	push	rbx
	push	r12
	push	r13
	push	r14
	mov	rbx,rdi				; out
	; count: the path's last segment
	mov	rsi,[g_hm+HM_TARGET]
	mov	ecx,[g_hm+HM_PLEN]
	lea	rdx,[rsi+rcx]
@@:
	cmp	rdx,rsi
	jbe	.bad
	cmp	byte [rdx-1],'/'
	je	@f
	dec	rdx
	jmp	@b
@@:
	lea	rcx,[rsi+rcx]			; the segment: rdx up to the path's end
	sub	rcx,rdx
	mov	rsi,rdx
	call	ha_atoi
	jc	.bad
	test	rax,rax
	js	.bad
	cmp	eax,[g_ha_n]
	jbe	@f
	mov	eax,[g_ha_n]
@@:
	mov	r12d,eax			; count
	; m: the query's m=
	mov	r13d,1
	ha_query
.q:
	cmp	r11d,2
	jb	.counted
	cmp	word [r10],'m='
	jne	.q_next
	lea	rsi,[r10+2]
	lea	ecx,[r11-2]
	call	ha_atoi
	jc	.q_next
	mov	r13,rax
	jmp	.counted
.q_next:
	; to the next parameter
	inc	r10
	dec	r11d
	jz	.counted
	cmp	byte [r10-1],'&'
	jne	.q_next
	jmp	.q
.counted:
	mov	rdi,rbx
	memit_hot '{"items":['
	xor	r14d,r14d
.item:
	cmp	r14d,r12d
	jae	.items_done
	test	r14d,r14d
	jz	@f
	mov	byte [rdi],','
	inc	rdi
@@:
	imul	rax,r14,HI_SIZE
	lea	r8,[g_ha_items+rax]
	memit_hot '{"id":'
	mov	rax,[r8+HI_ID]
	call	ha_itoa
	memit_hot ',"name":"'
	mov	rsi,[r8+HI_NAME]
	mov	ecx,[r8+HI_NLEN]
	call	copy_small
	memit_hot '","category":"'
	mov	rsi,[r8+HI_CAT]
	mov	ecx,[r8+HI_CLEN]
	call	copy_small
	memit_hot '","price":'
	mov	rax,[r8+HI_PRICE]
	call	ha_itoa
	memit_hot ',"quantity":'
	mov	rax,[r8+HI_QTY]
	call	ha_itoa
	cmp	dword [r8+HI_ACTIVE],0
	je	@f
	memit_hot ',"active":true,"tags":['
	jmp	.tags
@@:
	memit_hot ',"active":false,"tags":['
.tags:
	xor	r9d,r9d
.tag:
	cmp	r9d,[r8+HI_NTAGS]
	jae	.tags_done
	test	r9d,r9d
	jz	@f
	mov	byte [rdi],','
	inc	rdi
@@:
	mov	byte [rdi],'"'
	inc	rdi
	mov	eax,r9d
	shl	eax,4
	mov	rsi,[r8+HI_TAG+rax]
	mov	rcx,[r8+HI_TAG+rax+8]
	call	copy_small
	mov	byte [rdi],'"'
	inc	rdi
	inc	r9d
	jmp	.tag
.tags_done:
	memit_hot '],"rating":{"score":'
	mov	rax,[r8+HI_SCORE]
	call	ha_itoa
	memit_hot ',"count":'
	mov	rax,[r8+HI_COUNT]
	call	ha_itoa
	memit_hot '},"total":'
	mov	rax,[r8+HI_PRICE]
	imul	rax,[r8+HI_QTY]
	imul	rax,r13
	call	ha_itoa
	mov	byte [rdi],'}'
	inc	rdi
	inc	r14d
	jmp	.item
.items_done:
	memit_hot '],"count":'
	mov	eax,r12d
	call	ha_itoa
	mov	byte [rdi],'}'
	inc	rdi
	mov	rdx,rdi
	sub	rdx,rbx
	mov	eax,200
	lea	rsi,[ha_json_t]
	jmp	.out
.bad:
	xor	edx,edx
	mov	eax,404
	lea	rsi,[ha_text]
.out:
	xor	ecx,ecx				; (in the out buffer)
	pop	r14
	pop	r13
	pop	r12
	pop	rbx
	ret

; `handler echo`: the body, from where okena read it
ha_echo:
	mov	eax,ecx
	mov	rcx,rdx
	mov	edx,eax
	test	edx,edx
	jnz	@f
	xor	ecx,ecx				; (none: an empty answer)
@@:
	mov	eax,200
	lea	rsi,[ha_octet]
	ret

; `handler delay`: /delay/{ms}, the path's last segment; held, then answered
ha_delay:
	push	rbx
	push	r12
	mov	rbx,rdi
	mov	r12d,r10d			; back after the hold
	mov	rsi,[g_hm+HM_TARGET]
	mov	ecx,[g_hm+HM_PLEN]
	lea	rdx,[rsi+rcx]
	mov	r8,rdx				; the path's end
@@:
	cmp	rdx,rsi
	jbe	.bad
	cmp	byte [rdx-1],'/'
	je	@f
	dec	rdx
	jmp	@b
@@:
	mov	rcx,r8
	sub	rcx,rdx				; the segment's length
	jz	.bad
	mov	rsi,rdx
	call	ha_atoi
	jc	.bad
	test	ecx,ecx				; (all of it digits)
	jnz	.bad
	test	rax,rax
	js	.bad
	cmp	rax,HA_DELAY_MAX
	ja	.bad
	test	r12d,r12d
	jnz	.answer
	test	rax,rax
	jz	.answer				; 0: at once
	imul	edx,eax,1000			; µs
	xor	eax,eax				; held
	jmp	.out
.answer:
	mov	rdi,rbx
	call	ha_itoa
	mov	rdx,rdi
	sub	rdx,rbx
	mov	eax,200
	lea	rsi,[ha_text]
	xor	ecx,ecx
	jmp	.out
.bad:
	xor	edx,edx
	mov	eax,400
	lea	rsi,[ha_text]
	xor	ecx,ecx
.out:
	pop	r12
	pop	rbx
	ret

; `handler spec`: GET and HEAD a fixed text, OPTIONS the methods, POST its
; body back; /spec/headers the request's fields as `Name: Value` lines
ha_spec:
	push	rbx
	mov	rbx,rdi
	cmp	dword [g_hm+HM_PLEN],13		; /spec/headers
	jne	.method
	mov	rsi,[g_hm+HM_TARGET]
	cmp	dword [rsi+5],'/hea'
	jne	.method
	cmp	dword [rsi+9],'ders'
	jne	.method
	; the fields, while they fit
	lea	r10,[rbx+MOD_OUT_CAP]
	mov	rdi,rbx
	xor	r9d,r9d
.field:
	cmp	r9d,[g_hm+HM_NHDR]
	jae	.fields_done
	imul	rax,r9,HF_SIZE
	lea	r8,[g_hm+HM_HDRS+rax]
	inc	r9d
	mov	ecx,[r8+HF_NLEN]
	mov	edx,[r8+HF_VLEN]
	lea	rax,[rdi+rcx+4]			; name, ": ", value, CRLF
	add	rax,rdx
	cmp	rax,r10
	ja	.fields_done
	mov	rsi,[r8+HF_NAME]
	rep	movsb
	mov	word [rdi],': '
	add	rdi,2
	mov	rsi,[r8+HF_VALUE]
	mov	ecx,[r8+HF_VLEN]
	rep	movsb
	mov	word [rdi],0x0A0D
	add	rdi,2
	jmp	.field
.fields_done:
	mov	rdx,rdi
	sub	rdx,rbx
	mov	eax,200
	lea	rsi,[ha_text]
	xor	ecx,ecx
	pop	rbx
	ret
.method:
	mov	rsi,[g_hm+HM_METHOD]
	mov	eax,[g_hm+HM_MLEN]
	cmp	eax,3
	jne	@f
	cmp	word [rsi],'GE'
	jne	.other
	cmp	byte [rsi+2],'T'
	je	.text
	jmp	.other
@@:
	cmp	eax,4
	jne	@f
	cmp	dword [rsi],'HEAD'
	je	.text
	cmp	dword [rsi],'POST'
	jne	.other
	pop	rbx
	jmp	ha_echo				; (rdx/ecx: the body still)
@@:
	cmp	eax,7
	jne	.other
	cmp	dword [rsi],'OPTI'
	jne	.other
	cmp	dword [rsi+3],'IONS'
	jne	.other
	lea	rax,[ha_allow]
	mov	[g_mod_xh],rax
	mov	dword [g_mod_xhlen],ha_allow.len
	xor	edx,edx
	mov	eax,200
	jmp	.typed
.text:
	mov	dword [rbx],'spec'
	mov	dword [rbx+4],' ok'
	mov	edx,7
	mov	eax,200
	jmp	.typed
.other:
	lea	rax,[ha_allow]
	mov	[g_mod_xh],rax
	mov	dword [g_mod_xhlen],ha_allow.len
	xor	edx,edx
	mov	eax,405
.typed:
	lea	rsi,[ha_text]
	xor	ecx,ecx
	pop	rbx
	ret
