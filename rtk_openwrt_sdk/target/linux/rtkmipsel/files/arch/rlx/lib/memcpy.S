/*
 * This file is subject to the terms and conditions of the GNU General Public
 * License.  See the file "COPYING" in the main directory of this archive
 * for more details.
 *
 * Unified implementation of memcpy, memmove and the __copy_user backend.
 *
 * Copyright (C) 1998, 99, 2000, 01, 2002 Ralf Baechle (ralf@gnu.org)
 * Copyright (C) 1999, 2000, 01, 2002 Silicon Graphics, Inc.
 * Copyright (C) 2002 Broadcom, Inc.
 *   memcpy/copy_user author: Mark Vandevoorde
 * Copyright (C) 2007  Maciej W. Rozycki
 *
 * Modified for RLX processors
 * Copyright (C) 2008-2011 Tony Wu (tonywu@realtek.com)
 *
 * Mnemonic names for arguments to memcpy/__copy_user
 */

/*
 * Hack to resolve longstanding prefetch issue
 *
 * Prefetching may be fatal on some systems if we're prefetching beyond the
 * end of memory on some systems.  It's also a seriously bad idea on non
 * dma-coherent systems.
 */
#include <asm/asm.h>
#include <asm/asm-offsets.h>
#include <asm/regdef.h>

#define dst a0
#define src a1
#define len a2

/*
 * Spec
 *
 * memcpy copies len bytes from src to dst and sets v0 to dst.
 * It assumes that
 *   - src and dst don't overlap
 *   - src is readable
 *   - dst is writable
 * memcpy uses the standard calling convention
 *
 * __copy_user copies up to len bytes from src to dst and sets a2 (len) to
 * the number of uncopied bytes due to an exception caused by a read or write.
 * __copy_user assumes that src and dst don't overlap, and that the call is
 * implementing one of the following:
 *   copy_to_user
 *     - src is readable  (no exceptions when reading src)
 *   copy_from_user
 *     - dst is writable  (no exceptions when writing dst)
 * __copy_user uses a non-standard calling convention; see
 * include/asm-mips/uaccess.h
 *
 * When an exception happens on a load, the handler must
 # ensure that all of the destination buffer is overwritten to prevent
 * leaking information to user mode programs.
 */

/*
 * Implementation
 */

/*
 * The exception handler for loads requires that:
 *  1- AT contain the address of the byte just past the end of the source
 *     of the copy,
 *  2- src_entry <= src < AT, and
 *  3- (dst - src) == (dst_entry - src_entry),
 * The _entry suffix denotes values when __copy_user was called.
 *
 * (1) is set up up by uaccess.h and maintained by not writing AT in copy_user
 * (2) is met by incrementing src by the number of bytes copied
 * (3) is met by not doing loads between a pair of increments of dst and src
 *
 * The exception handlers for stores adjust len (if necessary) and return.
 * These handlers do not need to overwrite any data.
 *
 * For __rmemcpy and memmove an exception is always a kernel bug, therefore
 * they're not protected.
 */

#define EXC(inst_reg,addr,handler)		\
9:	inst_reg, addr;				\
	.section __ex_table,"a";		\
	PTR	9b, handler;			\
	.previous

#define LOAD   lw
#define LOADL  lwl
#define LOADR  lwr
#define STOREL swl
#define STORER swr
#define STORE  sw
#define ADD    addu
#define SUB    subu
#define SRL    srl
#define SLL    sll
#define SRA    sra
#define SLLV   sllv
#define SRLV   srlv
#define NBYTES 4
#define LOG_NBYTES 2

#ifdef CONFIG_CPU_LITTLE_ENDIAN
#define LDFIRST LOADR
#define LDREST	LOADL
#define STFIRST STORER
#define STREST	STOREL
#define SHIFT_DISCARD SLLV
#else
#define LDFIRST LOADL
#define LDREST	LOADR
#define STFIRST STOREL
#define STREST	STORER
#define SHIFT_DISCARD SRLV
#endif

#define FIRST(unit) ((unit)*NBYTES)
#define REST(unit)  (FIRST(unit)+NBYTES-1)
#define UNIT(unit)  FIRST(unit)

#define ADDRMASK (NBYTES-1)

	.text
	.set	noreorder
	.set	noat

/*
 * t6 is used as a flag to note inatomic mode.
 */
LEAF(__copy_user_inatomic)
	b	__copy_user_common
	 li	t6, 1
	END(__copy_user_inatomic)

/*
 * A combined memcpy/__copy_user
 * __copy_user sets len to 0 for success; else to an upper bound of
 * the number of uncopied bytes.
 * memcpy sets v0 to dst.
 */
	.align	5
LEAF(memcpy)					/* a0=dst a1=src a2=len */
	move	v0, dst				/* return value */
.L__memcpy:
FEXPORT(__copy_user)
	li	t6, 0	/* not inatomic */
__copy_user_common:
	/*
	 * Note: dst & src may be unaligned, len may be 0
	 * Temps
	 */
#define rem t8

	/*
	 * The "issue break"s below are very approximate.
	 * Issue delays for dcache fills will perturb the schedule, as will
	 * load queue full replay traps, etc.
	 *
	 * If len < NBYTES use byte operations.
	 */
#ifdef CONFIG_CPU_HAS_ULS
	sltu	t2, len, NBYTES
	and	t1, dst, ADDRMASK
	bnez	t2, .Lcopy_bytes_checklen
	 and	t0, src, ADDRMASK
	bnez	t1, .Ldst_unaligned
	 nop
	bnez	t0, .Lsrc_unaligned_dst_aligned
#else
	sltu	t2, len, NBYTES
	and	t1, dst, ADDRMASK
	and	t0, src, ADDRMASK
	or	t2, t1
	or	t2, t0
	bnez	t2, .Lcopy_bytes_checklen
#endif
	/*
	 * use delay slot for fall-through
	 * src and dst are aligned; need to compute rem
	 */
.Lboth_aligned:
	 SRL	t0, len, LOG_NBYTES+3	 # +3 for 8 units/iter
	beqz	t0, .Lcleanup_both_aligned # len < 8*NBYTES
	 and	rem, len, (8*NBYTES-1)	 # rem = len % (8*NBYTES)
	.align	4
1:
EXC(	LOAD	t0, UNIT(0)(src),	.Ll_exc)
EXC(	LOAD	t1, UNIT(1)(src),	.Ll_exc_copy)
EXC(	LOAD	t2, UNIT(2)(src),	.Ll_exc_copy)
EXC(	LOAD	t3, UNIT(3)(src),	.Ll_exc_copy)
	SUB	len, len, 8*NBYTES
EXC(	LOAD	t4, UNIT(4)(src),	.Ll_exc_copy)
EXC(	LOAD	t7, UNIT(5)(src),	.Ll_exc_copy)
EXC(	STORE	t0, UNIT(0)(dst),	.Ls_exc_p8u)
EXC(	STORE	t1, UNIT(1)(dst),	.Ls_exc_p7u)
EXC(	LOAD	t0, UNIT(6)(src),	.Ll_exc_copy)
EXC(	LOAD	t1, UNIT(7)(src),	.Ll_exc_copy)
	ADD	src, src, 8*NBYTES
	ADD	dst, dst, 8*NBYTES
EXC(	STORE	t2, UNIT(-6)(dst),	.Ls_exc_p6u)
EXC(	STORE	t3, UNIT(-5)(dst),	.Ls_exc_p5u)
EXC(	STORE	t4, UNIT(-4)(dst),	.Ls_exc_p4u)
EXC(	STORE	t7, UNIT(-3)(dst),	.Ls_exc_p3u)
EXC(	STORE	t0, UNIT(-2)(dst),	.Ls_exc_p2u)
EXC(	STORE	t1, UNIT(-1)(dst),	.Ls_exc_p1u)
	bne	len, rem, 1b
	 nop

	/*
	 * len == rem == the number of bytes left to copy < 8*NBYTES
	 */
.Lcleanup_both_aligned:
	beqz	len, .Ldone
	 sltu	t0, len, 4*NBYTES
	bnez	t0, .Lless_than_4units
	 and	rem, len, (NBYTES-1)	# rem = len % NBYTES
	/*
	 * len >= 4*NBYTES
	 */
EXC(	LOAD	t0, UNIT(0)(src),	.Ll_exc)
EXC(	LOAD	t1, UNIT(1)(src),	.Ll_exc_copy)
EXC(	LOAD	t2, UNIT(2)(src),	.Ll_exc_copy)
EXC(	LOAD	t3, UNIT(3)(src),	.Ll_exc_copy)
	SUB	len, len, 4*NBYTES
	ADD	src, src, 4*NBYTES
EXC(	STORE	t0, UNIT(0)(dst),	.Ls_exc_p4u)
EXC(	STORE	t1, UNIT(1)(dst),	.Ls_exc_p3u)
EXC(	STORE	t2, UNIT(2)(dst),	.Ls_exc_p2u)
EXC(	STORE	t3, UNIT(3)(dst),	.Ls_exc_p1u)
	beqz	len, .Ldone
	 ADD	dst, dst, 4*NBYTES
.Lless_than_4units:
	/*
	 * rem = len % NBYTES
	 */
	beq	rem, len, .Lcopy_bytes
	 nop
1:
EXC(	LOAD	t0, 0(src),		.Ll_exc)
	ADD	src, src, NBYTES
	SUB	len, len, NBYTES
EXC(	STORE	t0, 0(dst),		.Ls_exc_p1u)
	bne	rem, len, 1b
	 ADD	dst, dst, NBYTES

	/*
	 * src and dst are aligned, need to copy rem bytes (rem < NBYTES)
	 * A loop would do only a byte at a time with possible branch
	 * mispredicts.	 Can't do an explicit LOAD dst,mask,or,STORE
	 * because can't assume read-access to dst.  Instead, use
	 * STREST dst, which doesn't require read access to dst.
	 *
	 * This code should perform better than a simple loop on modern,
	 * wide-issue mips processors because the code has fewer branches and
	 * more instruction-level parallelism.
	 */
#ifdef CONFIG_CPU_HAS_ULS
#define bits t2
	beqz	len, .Ldone
	 ADD	t1, dst, len	# t1 is just past last byte of dst
	li	bits, 8*NBYTES
	SLL	rem, len, 3	# rem = number of bits to keep
EXC(	LOAD	t0, 0(src),		.Ll_exc)
	SUB	bits, bits, rem # bits = number of bits to discard
	SHIFT_DISCARD t0, t0, bits
EXC(	STREST	t0, -1(t1),		.Ls_exc)
	jr	ra
	 move	len, zero
.Ldst_unaligned:
	/*
	 * dst is unaligned
	 * t0 = src & ADDRMASK
	 * t1 = dst & ADDRMASK; T1 > 0
	 * len >= NBYTES
	 *
	 * Copy enough bytes to align dst
	 * Set match = (src and dst have same alignment)
	 */
#define match rem
EXC(	LDFIRST t3, FIRST(0)(src),	.Ll_exc)
	ADD	t2, zero, NBYTES
EXC(	LDREST	t3, REST(0)(src),	.Ll_exc_copy)
	SUB	t2, t2, t1	# t2 = number of bytes copied
	xor	match, t0, t1
EXC(	STFIRST t3, FIRST(0)(dst),	.Ls_exc)
	beq	len, t2, .Ldone
	 SUB	len, len, t2
	ADD	dst, dst, t2
	beqz	match, .Lboth_aligned
	 ADD	src, src, t2

.Lsrc_unaligned_dst_aligned:
	SRL	t0, len, LOG_NBYTES+2    # +2 for 4 units/iter
	beqz	t0, .Lcleanup_src_unaligned
	 and	rem, len, (4*NBYTES-1)   # rem = len % 4*NBYTES
1:
/*
 * Avoid consecutive LD*'s to the same register since some mips
 * implementations can't issue them in the same cycle.
 * It's OK to load FIRST(N+1) before REST(N) because the two addresses
 * are to the same unit (unless src is aligned, but it's not).
 */
EXC(	LDFIRST t0, FIRST(0)(src),	.Ll_exc)
EXC(	LDFIRST t1, FIRST(1)(src),	.Ll_exc_copy)
	SUB	len, len, 4*NBYTES
EXC(	LDREST	t0, REST(0)(src),	.Ll_exc_copy)
EXC(	LDREST	t1, REST(1)(src),	.Ll_exc_copy)
EXC(	LDFIRST t2, FIRST(2)(src),	.Ll_exc_copy)
EXC(	LDFIRST t3, FIRST(3)(src),	.Ll_exc_copy)
EXC(	LDREST	t2, REST(2)(src),	.Ll_exc_copy)
EXC(	LDREST	t3, REST(3)(src),	.Ll_exc_copy)
	ADD	src, src, 4*NBYTES
EXC(	STORE	t0, UNIT(0)(dst),	.Ls_exc_p4u)
EXC(	STORE	t1, UNIT(1)(dst),	.Ls_exc_p3u)
EXC(	STORE	t2, UNIT(2)(dst),	.Ls_exc_p2u)
EXC(	STORE	t3, UNIT(3)(dst),	.Ls_exc_p1u)
	bne	len, rem, 1b
	 ADD	dst, dst, 4*NBYTES

.Lcleanup_src_unaligned:
	beqz	len, .Ldone
	 and	rem, len, NBYTES-1  # rem = len % NBYTES
	beq	rem, len, .Lcopy_bytes
	 nop
1:
EXC(	LDFIRST t0, FIRST(0)(src),	.Ll_exc)
EXC(	LDREST	t0, REST(0)(src),	.Ll_exc_copy)
	ADD	src, src, NBYTES
	SUB	len, len, NBYTES
EXC(	STORE	t0, 0(dst),		.Ls_exc_p1u)
	bne	len, rem, 1b
	 ADD	dst, dst, NBYTES

.Lcopy_bytes_checklen:
	beqz	len, .Ldone
	 nop
.Lcopy_bytes:
	/* 0 < len < NBYTES  */
#define COPY_BYTE(N)			\
EXC(	lb	t0, N(src), .Ll_exc);	\
	SUB	len, len, 1;		\
	beqz	len, .Ldone;		\
EXC(	 sb	t0, N(dst), .Ls_exc_p1)

	COPY_BYTE(0)
	COPY_BYTE(1)
EXC(	lb	t0, NBYTES-2(src), .Ll_exc)
	SUB	len, len, 1
	jr	ra
EXC(	 sb	t0, NBYTES-2(dst), .Ls_exc_p1)

#else

.Lcopy_bytes_checklen:
	beqz	len, .Ldone
	 nop
.Lcopy_bytes:
EXC(	lb	t0,  0(src), .Ll_exc)
	SUB	len, len, 1
EXC(	sb	t0,  0(dst), .Ls_exc_p1)
	ADD	src, src, 1
	bnez	len, .Lcopy_bytes
	 ADD	dst, dst, 1
#endif

.Ldone:
	jr	ra
	 nop
	END(memcpy)

.Ll_exc_copy:
	/*
	 * Copy bytes from src until faulting load address (or until a
	 * lb faults)
	 *
	 * When reached by a faulting LDFIRST/LDREST, THREAD_BUADDR($28)
	 * may be more than a byte beyond the last address.
	 * Hence, the lb below may get an exception.
	 *
	 * Assumes src < THREAD_BUADDR($28)
	 */
	LOAD	t0, TI_TASK($28)
	 nop
	LOAD	t0, THREAD_BUADDR(t0)
1:
EXC(	lb	t1, 0(src),	.Ll_exc)
	ADD	src, src, 1
	sb	t1, 0(dst)	# can't fault -- we're copy_from_user
	bne	src, t0, 1b
	 ADD	dst, dst, 1
.Ll_exc:
	LOAD	t0, TI_TASK($28)
	 nop
	LOAD	t0, THREAD_BUADDR(t0)	# t0 is just past last good address
	 nop
	SUB	len, AT, t0		# len number of uncopied bytes
	bnez	t6, .Ldone	/* Skip the zeroing part if inatomic */
	/*
	 * Here's where we rely on src and dst being incremented in tandem,
	 *   See (3) above.
	 * dst += (fault addr - src) to put dst at first byte to clear
	 */
	ADD	dst, t0			# compute start address in a1
	SUB	dst, src
	/*
	 * Clear len bytes starting at dst.  Can't call __bzero because it
	 * might modify len.  An inefficient loop for these rare times...
	 */
	beqz	len, .Ldone
	 SUB	src, len, 1
1:	sb	zero, 0(dst)
	ADD	dst, dst, 1
	bnez	src, 1b
	 SUB	src, src, 1
	jr	ra
	 nop


#define SEXC(n)							\
.Ls_exc_p ## n ## u:						\
	jr	ra;						\
	 ADD	len, len, n*NBYTES;				\

SEXC(8)
SEXC(7)
SEXC(6)
SEXC(5)
SEXC(4)
SEXC(3)
SEXC(2)
SEXC(1)

.Ls_exc_p1:
	jr	ra
	 ADD	len, len, 1
.Ls_exc:
	jr	ra
	 nop

	.align	5
LEAF(memmove)
	ADD	t0, a0, a2
	ADD	t1, a1, a2
	sltu	t0, a1, t0			# dst + len <= src -> memcpy
	sltu	t1, a0, t1			# dst >= src + len -> memcpy
	and	t0, t1
	beqz	t0, .L__memcpy
	 move	v0, a0				/* return value */
	beqz	a2, .Lr_out
	END(memmove)

	/* fall through to __rmemcpy */
LEAF(__rmemcpy)					/* a0=dst a1=src a2=len */
	 sltu	t0, a1, a0
	beqz	t0, .Lr_end_bytes_up		# src >= dst
	 nop
	ADD	a0, a2				# dst = dst + len
	ADD	a1, a2				# src = src + len

.Lr_end_bytes:
	lb	t0, -1(a1)
	SUB	a2, a2, 0x1
	sb	t0, -1(a0)
	SUB	a1, a1, 0x1
	bnez	a2, .Lr_end_bytes
	 SUB	a0, a0, 0x1

.Lr_out:
	jr	ra
	 move	a2, zero

.Lr_end_bytes_up:
	lb	t0, (a1)
	SUB	a2, a2, 0x1
	sb	t0, (a0)
	ADD	a1, a1, 0x1
	bnez	a2, .Lr_end_bytes_up
	 ADD	a0, a0, 0x1

	jr	ra
	 move	a2, zero
	END(__rmemcpy)
