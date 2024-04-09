module EnzymeExt
    if isdefined(Base, :get_extension)
        using EnzymeCore
        using EnzymeCore.EnzymeRules
    else
        using ..EnzymeCore
        using ..EnzymeCore.EnzymeRules
    end
    using KernelAbstractions
    const KA = KernelAbstractions
    import KernelAbstractions: Kernel, StaticSize, launch_config, allocate,
                               blocks, mkcontext, CompilerMetadata, CPU, GPU, argconvert,
                               supports_enzyme, __fake_compiler_job, backend,
                               __index_Group_Cartesian, __index_Global_Linear
    # Last launched kernel per backend for synchronization
    const lastkernel = Dict()
    EnzymeRules.inactive(::Type{StaticSize}, x...) = nothing

    function fwd(ctx, f, args...)
        EnzymeCore.autodiff_deferred(Forward, Const(f), Const, Const(ctx), args...)
        return nothing
    end

    function EnzymeRules.forward(func::Const{<:Kernel}, ::Type{Const{Nothing}}, args...; ndrange=nothing, workgroupsize=nothing)
        kernel = func.val
        f = kernel.f
        fwd_kernel = similar(kernel, fwd)

        fwd_kernel(f, args...; ndrange, workgroupsize)
    end

    function _enzyme_mkcontext(kernel::Kernel{CPU}, ndrange, iterspace, dynamic)
        block = first(blocks(iterspace))
        return mkcontext(kernel, block, ndrange, iterspace, dynamic)
    end

    function _enzyme_mkcontext(kernel::Kernel{<:GPU}, ndrange, iterspace, dynamic)
        return mkcontext(kernel, ndrange, iterspace)
    end

    function _augmented_return(::Kernel{CPU}, subtape, arg_refs, tape_type)
        return AugmentedReturn{Nothing, Nothing, Tuple{Array, typeof(arg_refs), typeof(tape_type)}}(
            nothing, nothing, (subtape, arg_refs, tape_type)
        )
    end

    function _augmented_return(kernel::Kernel{<:GPU}, subtape, arg_refs, tape_type)
        # Was there a kernel launch before on this backend?
        # Put this on the tape for the reverse (implicit sync rule)
        # Nothing to put on the tape if no kernel was launched before.
        # Only needs an explicit sync in reverse.
        tape = (nothing)
        if haskey(lastkernel, backend(kernel))
            tape = lastkernel[backend(kernel)]
            pop!(lastkernel, backend(kernel))
            kernelsyncs[backend(kernel)] = (subtape, arg_refs, tape_type)
        end
        return AugmentedReturn{Nothing, Nothing, Any}(
            nothing, nothing, tape
        )
    end

    function _create_tape_kernel(
        kernel::Kernel{CPU}, ModifiedBetween,
        FT, ctxTy, ndrange, iterspace, args2...
    )
        TapeType = EnzymeCore.tape_type(
            ReverseSplitModified(ReverseSplitWithPrimal, ModifiedBetween),
            FT, Const,  Const{ctxTy}, map(Core.Typeof, args2)...
        )
        subtape = Array{TapeType}(undef, size(blocks(iterspace)))
        aug_kernel = similar(kernel, cpu_aug_fwd)
        return TapeType, subtape, aug_kernel
    end

    function _create_tape_kernel(
        kernel::Kernel{<:GPU}, ModifiedBetween,
        FT, ctxTy, ndrange, iterspace, args2...
    )
        # For peeking at the TapeType we need to first construct a correct compilation job
        # this requires the use of the device side representation of arguments.
        # So we convert the arguments here, this is a bit wasteful since the `aug_kernel` call
        # will later do the same.
        dev_args2 = ((argconvert(kernel, a) for a in args2)...,)
        dev_TT = map(Core.Typeof, dev_args2)

        job = __fake_compiler_job(backend(kernel))
        TapeType = EnzymeCore.tape_type(
            job, ReverseSplitModified(ReverseSplitWithPrimal, ModifiedBetween),
            FT, Const,  Const{ctxTy}, dev_TT...
        )

        # Allocate per thread
        subtape = allocate(backend(kernel), TapeType, prod(ndrange))

        aug_kernel = similar(kernel, gpu_aug_fwd)
        return TapeType, subtape, aug_kernel
    end

    _create_rev_kernel(kernel::Kernel{CPU})  = similar(kernel, cpu_rev)
    _create_rev_kernel(kernel::Kernel{<:GPU})  = similar(kernel, gpu_rev)

    function cpu_aug_fwd(
        ctx, f::FT, ::Val{ModifiedBetween}, subtape, ::Val{TapeType}, args...
    ) where {ModifiedBetween, FT, TapeType}
        # A2 = Const{Nothing} -- since f->Nothing
        forward, _ = EnzymeCore.autodiff_deferred_thunk(
            ReverseSplitModified(ReverseSplitWithPrimal, Val(ModifiedBetween)), TapeType,
            Const{Core.Typeof(f)}, Const, Const{Nothing},
            Const{Core.Typeof(ctx)}, map(Core.Typeof, args)...
        )

        # On the CPU: F is a per block function
        # On the CPU: subtape::Vector{Vector}
        I = __index_Group_Cartesian(ctx, #=fake=#CartesianIndex(1,1))
        subtape[I] = forward(Const(f), Const(ctx), args...)[1]
        return nothing
    end

    function cpu_rev(
        ctx, f::FT, ::Val{ModifiedBetween}, subtape, ::Val{TapeType}, args...
    ) where {ModifiedBetween, FT, TapeType}
        _, reverse = EnzymeCore.autodiff_deferred_thunk(
            ReverseSplitModified(ReverseSplitWithPrimal, Val(ModifiedBetween)), TapeType,
            Const{Core.Typeof(f)}, Const, Const{Nothing},
            Const{Core.Typeof(ctx)}, map(Core.Typeof, args)...
        )
        I = __index_Group_Cartesian(ctx, #=fake=#CartesianIndex(1,1))
        tp = subtape[I]
        reverse(Const(f), Const(ctx), args..., tp)
        return nothing
    end

    function EnzymeRules.reverse(config::Config, func::Const{<:Kernel}, ::Type{<:EnzymeCore.Annotation}, tape, args::Vararg{Any, N}; ndrange=nothing, workgroupsize=nothing) where N
        subtape, arg_refs, tape_type = tape

        args2 = ntuple(Val(N)) do i
            Base.@_inline_meta
            if args[i] isa Active
                Duplicated(Ref(args[i].val), arg_refs[i])
            else
                args[i]
            end
        end

        kernel = func.val
        f = kernel.f

        tup = Val(ntuple(Val(N)) do i
            Base.@_inline_meta
            args[i] isa Active
        end)
        f = make_active_byref(f, tup)

        ModifiedBetween = Val((overwritten(config)[1], false, overwritten(config)[2:end]...))

        rev_kernel = _create_rev_kernel(kernel)
        rev_kernel(f, ModifiedBetween, subtape, Val(tape_type), args2...; ndrange, workgroupsize)
        res = ntuple(Val(N)) do i
            Base.@_inline_meta
            if args[i] isa Active
                arg_refs[i][]
            else
                nothing
            end
        end
        KernelAbstractions.synchronize(backend(kernel))
        return res
    end

    # GPU support
    function gpu_aug_fwd(
        ctx, f::FT, ::Val{ModifiedBetween}, subtape, ::Val{TapeType}, args...
    ) where {ModifiedBetween, FT, TapeType}
        # A2 = Const{Nothing} -- since f->Nothing
        forward, _ = EnzymeCore.autodiff_deferred_thunk(
            ReverseSplitModified(ReverseSplitWithPrimal, Val(ModifiedBetween)), TapeType,
            Const{Core.Typeof(f)}, Const, Const{Nothing},
            Const{Core.Typeof(ctx)}, map(Core.Typeof, args)...
        )

        # On the GPU: F is a per thread function
        # On the GPU: subtape::Vector
        I = __index_Global_Linear(ctx)
        subtape[I] = forward(Const(f), Const(ctx), args...)[1]
        return nothing
    end

    function gpu_rev(
        ctx, f::FT, ::Val{ModifiedBetween}, subtape, ::Val{TapeType}, args...
    ) where {ModifiedBetween, FT, TapeType}
        # XXX: TapeType and A2 as args to autodiff_deferred_thunk
        _, reverse = EnzymeCore.autodiff_deferred_thunk(
            ReverseSplitModified(ReverseSplitWithPrimal, Val(ModifiedBetween)), TapeType,
            Const{Core.Typeof(f)}, Const, Const{Nothing},
            Const{Core.Typeof(ctx)}, map(Core.Typeof, args)...
        )
        I = __index_Global_Linear(ctx)
        tp = subtape[I]
        reverse(Const(f), Const(ctx), args..., tp)
        return nothing
    end

    function EnzymeRules.augmented_primal(
        config::Config, func::Const{<:Kernel},
        ::Type{Const{Nothing}}, args::Vararg{Any, N}; ndrange=nothing, workgroupsize=nothing
        ) where N
        kernel = func.val
        if !supports_enzyme(backend(kernel))
            error("KernelAbstractions backend does not support Enzyme")
        end
        f = kernel.f

        ndrange, workgroupsize, iterspace, dynamic = launch_config(kernel, ndrange, workgroupsize)
        ctx = _enzyme_mkcontext(kernel, ndrange, iterspace, dynamic)
        ctxTy = Core.Typeof(ctx) # CompilerMetadata{ndrange(kernel), Core.Typeof(dynamic)}
        # TODO autodiff_deferred on the func.val
        ModifiedBetween = Val((overwritten(config)[1], false, overwritten(config)[2:end]...))

        tup = Val(ntuple(Val(N)) do i
            Base.@_inline_meta
            args[i] isa Active
        end)
        f = make_active_byref(f, tup)
        FT = Const{Core.Typeof(f)}

        arg_refs = ntuple(Val(N)) do i
            Base.@_inline_meta
            if args[i] isa Active
                Ref(EnzymeCore.make_zero(args[i].val))
            else
                nothing
            end
        end
        args2 = ntuple(Val(N)) do i
            Base.@_inline_meta
            if args[i] isa Active
                Duplicated(Ref(args[i].val), arg_refs[i])
            else
                args[i]
            end
        end

        TapeType, subtape, aug_kernel = _create_tape_kernel(
            kernel, ModifiedBetween, FT, ctxTy, ndrange, iterspace, args2...
        )
        aug_kernel(f, ModifiedBetween, subtape, Val(TapeType), args2...; ndrange, workgroupsize)

        # TODO the fact that ctxTy is type unstable means this is all type unstable.
        # Since custom rules require a fixed return type, explicitly cast to Any, rather
        # than returning a AugmentedReturn{Nothing, Nothing, T} where T.
        return _augmented_return(kernel, subtape, arg_refs, TapeType)
    end

    @inline function make_active_byref(f::F, ::Val{ActiveTys}) where {F, ActiveTys}
    if !any(ActiveTys)
        return f
    end
    function inact(ctx, args2::Vararg{Any, N}) where N
        args3 = ntuple(Val(N)) do i
            Base.@_inline_meta
            if ActiveTys[i]
                args2[i][]
            else
                args2[i]
            end
        end
        f(ctx, args3...)
    end
    return inact
end

# Synchronize rules
# TODO: Right now we do the synchronization as part of the kernel launch in the augmented primal
#       and reverse rules. This is not ideal, as we would want to launch the kernel in the reverse
#       synchronize rule and then synchronize where the launch was. However, with the current
#       kernel semantics this ensures correctness for now.
function EnzymeRules.augmented_primal(
    config::Config,
    func::Const{typeof(KA.synchronize)},
    ::Type{Const{Nothing}},
    backend::T
) where T <: EnzymeCore.Annotation
    KernelAbstractions.synchronize(backend.val)
    # Was there a kernel launched before on this backend
    tape = (nothing)
    if haskey(lastkernel, backend.val)
        tape = lastkernel[backend.val]
        pop!(lastkernel, backend.val)
    end
    return AugmentedReturn{Nothing, Nothing, Any}(
        nothing, nothing, tape
    )
end

function EnzymeRules.reverse(config::Config, func::Const{typeof(KA.synchronize)}, ::Type{Const{Nothing}}, tape, backend)
    # noop for now
    return (nothing,)
end

end
