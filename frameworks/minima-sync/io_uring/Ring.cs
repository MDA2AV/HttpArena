using System.Runtime.CompilerServices;
using static Minima.Native;

// ReSharper disable SuggestVarOrType_BuiltInTypes
// ReSharper disable SuggestVarOrType_Elsewhere
#pragma warning disable CA1806

namespace Minima;

public sealed unsafe class Ring : IDisposable 
{
    private int _fd;

    public int Fd => _fd;
    
    private uint*       _sqHead;   
    private uint*       _sqTail;    
    private uint*       _sqArray;    
    private uint        _sqMask;
    private uint        _sqEntries;
    private IoUringSqe* _sqes;       
    
    private uint*       _cqHead;    
    private uint*       _cqTail;    
    private IoUringCqe* _cqes;
    private uint        _cqMask;

    private uint _sqeTail;
    
    private byte* _ringPtr;
    private nuint _ringSize;
    private byte* _sqePtr;
    private nuint _sqeSize;
    
    public static Ring Create(uint entries) 
    {
        IoUringParams ioUringParams = default;
        ioUringParams.flags = IORING_SETUP_SINGLE_ISSUER | IORING_SETUP_DEFER_TASKRUN;
        int fd = io_uring_setup(entries, &ioUringParams);
        if (fd < 0)
        {
            throw new InvalidOperationException($"io_uring_setup failed: {fd}");
        }

        var ring = new Ring
        {
            _fd = fd, 
            _sqEntries = ioUringParams.sq_entries 
        };
        
        nuint sqRingBytes = ioUringParams.sq_off.array + ioUringParams.sq_entries * sizeof(uint);
        nuint cqRingBytes = ioUringParams.cq_off.cqes  + ioUringParams.cq_entries * (nuint)sizeof(IoUringCqe);
        nuint ringBytes   = sqRingBytes > cqRingBytes ? sqRingBytes : cqRingBytes;

        void* ringMem = mmap(null, ringBytes, PROT_READ | PROT_WRITE, MAP_SHARED | MAP_POPULATE, fd, IORING_OFF_SQ_RING);
        if (ringMem == (void*)-1)
        {
            close(fd); 
            
            throw new InvalidOperationException("mmap(SQ_RING) failed"); 
        }
        ring._ringPtr  = (byte*)ringMem;
        ring._ringSize = ringBytes;
        
        nuint sqeBytes = ioUringParams.sq_entries * (nuint)sizeof(IoUringSqe);
        void* sqeMem = mmap(null, sqeBytes, PROT_READ | PROT_WRITE, MAP_SHARED | MAP_POPULATE, fd, IORING_OFF_SQES);
        if (sqeMem == (void*)-1)
        {
            munmap(ringMem, ringBytes); 
            close(fd); 
            
            throw new InvalidOperationException("mmap(SQES) failed"); 
        }
        ring._sqes    = (IoUringSqe*)sqeMem;
        ring._sqePtr  = (byte*)sqeMem;
        ring._sqeSize = sqeBytes; 
        
        byte* ringPointer = (byte*)ringMem;
        ring._sqHead  = (uint*)(ringPointer + ioUringParams.sq_off.head);
        ring._sqTail  = (uint*)(ringPointer + ioUringParams.sq_off.tail);
        ring._sqArray = (uint*)(ringPointer + ioUringParams.sq_off.array);
        ring._sqMask  = *(uint*)(ringPointer + ioUringParams.sq_off.ring_mask);

        ring._cqHead = (uint*)(ringPointer + ioUringParams.cq_off.head);
        ring._cqTail = (uint*)(ringPointer + ioUringParams.cq_off.tail);
        ring._cqes   = (IoUringCqe*)(ringPointer + ioUringParams.cq_off.cqes);
        ring._cqMask = *(uint*)(ringPointer + ioUringParams.cq_off.ring_mask);

        return ring;
    }
    
    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    public IoUringSqe* GetSqe() 
    {
        uint head = Volatile.Read(ref *_sqHead);
        
        if (_sqeTail - head >= _sqEntries)
        {
            return null;
        }

        uint slot = _sqeTail & _sqMask;
        _sqArray[slot] = slot;         
        _sqeTail++;
        
        return &_sqes[slot];
    }
    
    public int SubmitAndWait(uint waitFor) 
    {
        uint published = *_sqTail;
        uint toSubmit  = _sqeTail - published;
        
        if (toSubmit > 0)
        {
            Volatile.Write(ref *_sqTail, _sqeTail);
        }

        if (toSubmit == 0 && waitFor == 0) return 0;

        uint flags = waitFor > 0 ? IORING_ENTER_GETEVENTS : 0;
        
        return io_uring_enter(_fd, toSubmit, waitFor, flags);
    }
    
    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    public bool TryGetCqe(out IoUringCqe cqe) 
    {
        uint head = *_cqHead;
        uint tail = Volatile.Read(ref *_cqTail);

        if (head == tail)
        {
            cqe = default; 
            
            return false; 
        }

        cqe = _cqes[head & _cqMask];
        
        return true;
    }
    
    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    public void CqeSeen() => Volatile.Write(ref *_cqHead, *_cqHead + 1);

    // Batched CQ drain (liburing io_uring_for_each_cqe + io_uring_cq_advance):
    // read the kernel-written tail once (acquire), process the whole batch,
    // then publish the consumed head once (release) instead of once per CQE.

    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    public uint CqReady() => Volatile.Read(ref *_cqTail) - *_cqHead;

    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    public ref readonly IoUringCqe CqeAt(uint i) => ref _cqes[(*_cqHead + i) & _cqMask];

    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    public void CqAdvance(uint n) => Volatile.Write(ref *_cqHead, *_cqHead + n);

    public void Dispose()
    {
        if (_ringPtr != null)
        {
            munmap(_ringPtr, _ringSize); _ringPtr = null; 
        }

        if (_sqePtr != null)
        {
            munmap(_sqePtr,  _sqeSize);  _sqePtr  = null; 
        }

        if (_fd > 0)
        {
            close(_fd); _fd = 0; 
        }
    }
}

#pragma warning restore CA1806
