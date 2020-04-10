using Test, Base.CoreLogging
import Base.CoreLogging: Info

using GPUCompiler

import LLVM

include("util.jl")

# create a minimal PTX-based compiler, and generate reflection methods for it
ptx_cap = v"7.0"
ptx_runtime = @eval module $(gensym("Runtime"))
    # the GPU runtime library
    signal_exception() = return
    malloc(sz) = return
    report_oom(sz) = return
    report_exception(ex) = return
    report_exception_name(ex) = return
    report_exception_frame(idx, func, file, line) = return
    # for validation
    sin(x) = Base.sin(x)
end
for method in (:code_typed, :code_warntype, :code_llvm, :code_native)
    # only code_typed doesn't take a io argument
    args = method == :code_typed ? (:job,) : (:io, :job)
    ptx_method = Symbol("ptx_$(method)")

    @eval begin
        function $ptx_method(io::IO, @nospecialize(func), @nospecialize(types);
                             kernel::Bool=false, minthreads=nothing, maxthreads=nothing,
                             blocks_per_sm=nothing, maxregs=nothing, kwargs...)
            source = FunctionSpec(func, Base.to_tuple_type(types), kernel)
            target = PTXCompilerTarget($ptx_cap; runtime_module=$ptx_runtime)
            job = PTXCompilerJob(target, source;
                                 minthreads=minthreads, maxthreads=maxthreads,
                                 blocks_per_sm=blocks_per_sm, maxregs=maxregs)
            GPUCompiler.$method($(args...); kwargs...)
        end
        $ptx_method(@nospecialize(func), @nospecialize(types); kwargs...) =
            $ptx_method(stdout, func, types; kwargs...)
    end
end
GPUCompiler.reset_runtime()

@testset "GPUCompiler" begin

GPUCompiler.enable_timings()

############################################################################################

@testset "LLVM IR" begin

@testset "basic reflection" begin
    valid_kernel() = return
    invalid_kernel() = 1

    ir = sprint(io->ptx_code_llvm(io, valid_kernel, Tuple{}; optimize=false, dump_module=true))

    # module should contain our function + a generic call wrapper
    @test occursin(r"define\ .* void\ @.*julia_valid_kernel.*\(\)"x, ir)
    @test !occursin("define %jl_value_t* @jlcall_", ir)

    # there should be no debug metadata
    @test !occursin("!dbg", ir)

    @test ptx_code_llvm(devnull, invalid_kernel, Tuple{}) == nothing
    @test_throws KernelError ptx_code_llvm(devnull, invalid_kernel, Tuple{}; kernel=true) == nothing
end

@testset "unbound typevars" begin
    invalid_kernel() where {unbound} = return
    @test_throws KernelError ptx_code_llvm(devnull, invalid_kernel, Tuple{})
end

@testset "exceptions" begin
    foobar() = throw(DivideError())
    ir = sprint(io->ptx_code_llvm(io, foobar, Tuple{}))

    # plain exceptions should get lowered to a call to the GPU run-time
    @test occursin("gpu_report_exception", ir)
    # not a jl_throw referencing a jl_value_t representing the exception
    @test !occursin("jl_throw", ir)
end

@testset "sysimg" begin
    # bug: use a system image function

    function foobar(a,i)
        Base.pointerset(a, 0, mod1(i,10), 8)
    end

    ir = sprint(io->ptx_code_llvm(io, foobar, Tuple{Ptr{Int},Int}))
    @test !occursin("jlsys_", ir)
end

@testset "child functions" begin
    # we often test using `@noinline sink` child functions, so test whether these survive
    @noinline child(i) = sink(i)
    parent(i) = child(i)

    ir = sprint(io->ptx_code_llvm(io, parent, Tuple{Int}))
    @test occursin(r"call .+ @julia_child_", ir)
end

@testset "kernel functions" begin
@testset "wrapper function aggregate rewriting" begin
    kernel(x) = return

    @eval struct Aggregate
        x::Int
    end

    ir = sprint(io->ptx_code_llvm(io, kernel, Tuple{Aggregate}))
    @test occursin(r"@.*julia_kernel.+\(({ i64 }|\[1 x i64\]) addrspace\(\d+\)?\*", ir)

    ir = sprint(io->ptx_code_llvm(io, kernel, Tuple{Aggregate}; kernel=true))
    @test occursin(r"@.*julia_kernel.+\(({ i64 }|\[1 x i64\])\)", ir)
end

@testset "property_annotations" begin
    kernel() = return

    ir = sprint(io->ptx_code_llvm(io, kernel, Tuple{}; dump_module=true))
    @test !occursin("nvvm.annotations", ir)

    ir = sprint(io->ptx_code_llvm(io, kernel, Tuple{};
                                         dump_module=true, kernel=true))
    @test occursin("nvvm.annotations", ir)
    @test !occursin("maxntid", ir)
    @test !occursin("reqntid", ir)
    @test !occursin("minctasm", ir)
    @test !occursin("maxnreg", ir)

    ir = sprint(io->ptx_code_llvm(io, kernel, Tuple{};
                                         dump_module=true, kernel=true, maxthreads=42))
    @test occursin("maxntidx\", i32 42", ir)
    @test occursin("maxntidy\", i32 1", ir)
    @test occursin("maxntidz\", i32 1", ir)

    ir = sprint(io->ptx_code_llvm(io, kernel, Tuple{};
                                         dump_module=true, kernel=true, minthreads=42))
    @test occursin("reqntidx\", i32 42", ir)
    @test occursin("reqntidy\", i32 1", ir)
    @test occursin("reqntidz\", i32 1", ir)

    ir = sprint(io->ptx_code_llvm(io, kernel, Tuple{};
                                         dump_module=true, kernel=true, blocks_per_sm=42))
    @test occursin("minctasm\", i32 42", ir)

    ir = sprint(io->ptx_code_llvm(io, kernel, Tuple{};
                                         dump_module=true, kernel=true, maxregs=42))
    @test occursin("maxnreg\", i32 42", ir)
end
end

@testset "tracked pointers" begin
    function kernel(a)
        a[1] = 1
        return
    end

    # this used to throw an LLVM assertion (#223)
    ptx_code_llvm(devnull, kernel, Tuple{Vector{Int}}; kernel=true)
end

if VERSION >= v"1.0.2"
@testset "CUDAnative.jl#278" begin
    # codegen idempotency
    # NOTE: this isn't fixed, but surfaces here due to bad inference of checked_sub
    # NOTE: with the fix to print_to_string this doesn't error anymore,
    #       but still have a test to make sure it doesn't regress
    ptx_code_llvm(devnull, Base.checked_sub, Tuple{Int,Int}; optimize=false)
    ptx_code_llvm(devnull, Base.checked_sub, Tuple{Int,Int}; optimize=false)

    # breaking recursion in print_to_string makes it possible to compile
    # even in the presence of the above bug
    ptx_code_llvm(devnull, Base.print_to_string, Tuple{Int,Int}; optimize=false)
end
end

@testset "LLVM D32593" begin
    @eval struct D32593_struct
        foo::Float32
        bar::Float32
    end

    D32593(ptr) = unsafe_load(ptr).foo

    ptx_code_llvm(devnull, D32593, Tuple{Ptr{D32593_struct}})
end

end

############################################################################################

@testset "PTX assembly" begin

@testset "basic reflection" begin
    valid_kernel() = return
    invalid_kernel() = 1

    @test ptx_code_native(devnull, valid_kernel, Tuple{}) == nothing
    @test ptx_code_native(devnull, invalid_kernel, Tuple{}) == nothing
    @test_throws KernelError ptx_code_native(devnull, invalid_kernel, Tuple{}; kernel=true)
end

@testset "child functions" begin
    # we often test using @noinline child functions, so test whether these survive
    # (despite not having side-effects)
    @noinline child(i) = sink(i)
    function parent(i)
        child(i)
        return
    end

    asm = sprint(io->ptx_code_native(io, parent, Tuple{Int64}))
    @test occursin(r"call.uni\s+julia_.*child_"m, asm)
end

@testset "kernel functions" begin
    @noinline nonentry(i) = sink(i)
    function entry(i)
        nonentry(i)
        return
    end

    asm = sprint(io->ptx_code_native(io, entry, Tuple{Int64}; kernel=true))
    @test occursin(r"\.visible \.entry .*julia_entry", asm)
    @test !occursin(r"\.visible \.func .*julia_nonentry", asm)
    @test occursin(r"\.func .*julia_nonentry", asm)

@testset "property_annotations" begin
    asm = sprint(io->ptx_code_native(io, entry, Tuple{Int64}; kernel=true))
    @test !occursin("maxntid", asm)

    asm = sprint(io->ptx_code_native(io, entry, Tuple{Int64};
                                         kernel=true, maxthreads=42))
    @test occursin(".maxntid 42, 1, 1", asm)

    asm = sprint(io->ptx_code_native(io, entry, Tuple{Int64};
                                         kernel=true, minthreads=42))
    @test occursin(".reqntid 42, 1, 1", asm)

    asm = sprint(io->ptx_code_native(io, entry, Tuple{Int64};
                                         kernel=true, blocks_per_sm=42))
    @test occursin(".minnctapersm 42", asm)

    if LLVM.version() >= v"4.0"
        asm = sprint(io->ptx_code_native(io, entry, Tuple{Int64};
                                             kernel=true, maxregs=42))
        @test occursin(".maxnreg 42", asm)
    end
end
end

@testset "idempotency" begin
    # bug: generate code twice for the same kernel (jl_to_ptx wasn't idempotent)

    kernel() = return
    ptx_code_native(devnull, kernel, Tuple{})
    ptx_code_native(devnull, kernel, Tuple{})
end

@testset "child function reuse" begin
    # bug: depending on a child function from multiple parents resulted in
    #      the child only being present once

    @noinline child(i) = sink(i)
    function parent1(i)
        child(i)
        return
    end

    asm = sprint(io->ptx_code_native(io, parent1, Tuple{Int}))
    @test occursin(r".func julia_.*child_", asm)

    function parent2(i)
        child(i+1)
        return
    end

    asm = sprint(io->ptx_code_native(io, parent2, Tuple{Int}))
    @test occursin(r".func julia_.*child_", asm)
end

@testset "child function reuse bis" begin
    # bug: similar, but slightly different issue as above
    #      in the case of two child functions
    @noinline child1(i) = sink(i)
    @noinline child2(i) = sink(i+1)
    function parent1(i)
        child1(i) + child2(i)
        return
    end
    ptx_code_native(devnull, parent1, Tuple{Int})

    function parent2(i)
        child1(i+1) + child2(i+1)
        return
    end
    ptx_code_native(devnull, parent2, Tuple{Int})
end

@testset "indirect sysimg function use" begin
    # issue #9: re-using sysimg functions should force recompilation
    #           (host fldmod1->mod1 throws, so the PTX code shouldn't contain a throw)

    # NOTE: Int32 to test for #49

    function kernel(out)
        wid, lane = fldmod1(unsafe_load(out), Int32(32))
        unsafe_store!(out, wid)
        return
    end

    asm = sprint(io->ptx_code_native(io, kernel, Tuple{Ptr{Int32}}))
    @test !occursin("jl_throw", asm)
    @test !occursin("jl_invoke", asm)   # forced recompilation should still not invoke
end

@testset "compile for host after PTX" begin
    # issue #11: re-using host functions after PTX compilation
    @noinline child(i) = sink(i+1)

    function fromhost()
        child(10)
    end

    function fromptx()
        child(10)
        return
    end

    ptx_code_native(devnull, fromptx, Tuple{})
    @test fromhost() == 11
end

@testset "LLVM intrinsics" begin
    # issue #13 (a): cannot select trunc
    function kernel(x)
        unsafe_trunc(Int, x)
        return
    end
    ptx_code_native(devnull, kernel, Tuple{Float64})
end

@testset "exception arguments" begin
    function kernel(a)
        unsafe_store!(a, trunc(Int, unsafe_load(a)))
        return
    end

    ptx_code_native(devnull, kernel, Tuple{Ptr{Float64}})
end

@testset "GC and TLS lowering" begin
    @eval mutable struct PleaseAllocate
        y::Csize_t
    end

    # common pattern in Julia 0.7: outlined throw to avoid a GC frame in the calling code
    @noinline function inner(x)
        sink(x.y)
        nothing
    end

    function kernel(i)
        inner(PleaseAllocate(Csize_t(42)))
        nothing
    end

    asm = sprint(io->ptx_code_native(io, kernel, Tuple{Int}))
    @test occursin("gpu_gc_pool_alloc", asm)

    # make sure that we can still ellide allocations
    function ref_kernel(ptr, i)
        data = Ref{Int64}()
        data[] = 0
        if i > 1
            data[] = 1
        else
            data[] = 2
        end
        unsafe_store!(ptr, data[], i)
        return nothing
    end

    asm = sprint(io->ptx_code_native(io, ref_kernel, Tuple{Ptr{Int64}, Int}))


    if VERSION < v"1.2.0-DEV.375"
        @test_broken !occursin("gpu_gc_pool_alloc", asm)
    else
        @test !occursin("gpu_gc_pool_alloc", asm)
    end
end

@testset "float boxes" begin
    function kernel(a,b)
        c = Int32(a)
        # the conversion to Int32 may fail, in which case the input Float32 is boxed in order to
        # pass it to the @nospecialize exception constructor. we should really avoid that (eg.
        # by avoiding @nospecialize, or optimize the unused arguments away), but for now the box
        # should just work.
        unsafe_store!(b, c)
        return
    end

    ir = sprint(io->ptx_code_llvm(io, kernel, Tuple{Float32,Ptr{Float32}}))
    @test occursin("jl_box_float32", ir)
    ptx_code_native(devnull, kernel, Tuple{Float32,Ptr{Float32}})
end

end


############################################################################################

@testset "errors" begin

# some validation happens in the emit_function hook, which is called by ptx_code_llvm

@testset "base intrinsics" begin
    foobar(i) = sin(i)

    # NOTE: we don't use test_logs in order to test all of the warning (exception, backtrace)
    logs, _ = Test.collect_test_logs(min_level=Info) do
        withenv("JULIA_DEBUG" => nothing) do
            ptx_code_llvm(devnull, foobar, Tuple{Int})
        end
    end
    @test length(logs) == 1
    record = logs[1]
    @test record.level == Base.CoreLogging.Warn
    @test record.message == "calls to Base intrinsics might be GPU incompatible"
    @test haskey(record.kwargs, :exception)
    err,bt = record.kwargs[:exception]
    err_msg = sprint(showerror, err)
    @test occursin(Regex("You called sin(.+) in Base.Math .+, maybe you intended to call sin(.+) in $ptx_runtime .+ instead?"), err_msg)
    bt_msg = sprint(Base.show_backtrace, bt)
    @test occursin("[1] sin", bt_msg)
    @test occursin(r"\[2\] .+foobar", bt_msg)
end

# some validation happens in `compile`

@eval Main begin
struct CleverType{T}
    x::T
end
Base.unsafe_trunc(::Type{Int}, x::CleverType) = unsafe_trunc(Int, x.x)
end

@testset "non-isbits arguments" begin
    foobar(i) = (sink(unsafe_trunc(Int,i)); return)

    @test_throws_message(KernelError,
                         ptx_code_llvm(foobar, Tuple{BigInt}; strict=true)) do msg
        occursin("passing and using non-bitstype argument", msg) &&
        occursin("BigInt", msg)
    end

    # test that we can handle abstract types
    @test_throws_message(KernelError,
                         ptx_code_llvm(foobar, Tuple{Any}; strict=true)) do msg
        occursin("passing and using non-bitstype argument", msg) &&
        occursin("Any", msg)
    end

    @test_throws_message(KernelError,
                         ptx_code_llvm(foobar, Tuple{Union{Int32, Int64}}; strict=true)) do msg
        occursin("passing and using non-bitstype argument", msg) &&
        occursin("Union{Int32, Int64}", msg)
    end

    @test_throws_message(KernelError,
                         ptx_code_llvm(foobar, Tuple{Union{Int32, Int64}}; strict=true)) do msg
        occursin("passing and using non-bitstype argument", msg) &&
        occursin("Union{Int32, Int64}", msg)
    end

    # test that we get information about fields and reason why something is not isbits
    @test_throws_message(KernelError,
                         ptx_code_llvm(foobar, Tuple{CleverType{BigInt}}; strict=true)) do msg
        occursin("passing and using non-bitstype argument", msg) &&
        occursin("CleverType", msg) &&
        occursin("BigInt", msg)
    end
end

@testset "invalid LLVM IR" begin
    foobar(i) = println(i)

    @test_throws_message(InvalidIRError,
                         ptx_code_llvm(foobar, Tuple{Int}; strict=true)) do msg
        occursin("invalid LLVM IR", msg) &&
        occursin(GPUCompiler.RUNTIME_FUNCTION, msg) &&
        occursin("[1] println", msg) &&
        occursin(r"\[2\] .+foobar", msg)
    end
end

@testset "invalid LLVM IR (ccall)" begin
    foobar(p) = (unsafe_store!(p, ccall(:time, Cint, ())); nothing)

    @test_throws_message(InvalidIRError,
                         ptx_code_llvm(foobar, Tuple{Ptr{Int}}; strict=true)) do msg
        occursin("invalid LLVM IR", msg) &&
        occursin(GPUCompiler.POINTER_FUNCTION, msg) &&
        occursin(r"\[1\] .+foobar", msg)
    end
end

@testset "delayed bindings" begin
    kernel() = (undefined; return)

    @test_throws_message(InvalidIRError,
                         ptx_code_llvm(kernel, Tuple{}; strict=true)) do msg
        occursin("invalid LLVM IR", msg) &&
        occursin(GPUCompiler.DELAYED_BINDING, msg) &&
        occursin("use of 'undefined'", msg) &&
        occursin(r"\[1\] .+kernel", msg)
    end
end

@testset "dynamic call (invoke)" begin
    @eval @noinline nospecialize_child(@nospecialize(i)) = i
    kernel(a, b) = (unsafe_store!(b, nospecialize_child(a)); return)

    @test_throws_message(InvalidIRError,
                         ptx_code_llvm(kernel, Tuple{Int,Ptr{Int}}; strict=true)) do msg
        occursin("invalid LLVM IR", msg) &&
        occursin(GPUCompiler.DYNAMIC_CALL, msg) &&
        occursin("call to nospecialize_child", msg) &&
        occursin(r"\[1\] .+kernel", msg)
    end
end

@testset "dynamic call (apply)" begin
    func() = pointer(1)

    @test_throws_message(InvalidIRError,
                         ptx_code_llvm(func, Tuple{}; strict=true)) do msg
        occursin("invalid LLVM IR", msg) &&
        occursin(GPUCompiler.DYNAMIC_CALL, msg) &&
        occursin("call to pointer", msg) &&
        occursin("[1] func", msg)
    end
end

end

############################################################################################

haskey(ENV, "CI") && GPUCompiler.timings()

end
