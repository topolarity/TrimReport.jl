using JuliaSyntax
using JuliaLowering

const JS = JuliaSyntax
const JL = JuliaLowering

orig_nodes(st5::JL.SyntaxTree) = _orig_nodes!(st5, st5.source, JL.SyntaxList(st5))

# duplicates are OK
function _orig_nodes!(st5, src, out)
    if src isa JL.SourceRef || src isa LineNumberNode
        push!(out, st5)
    elseif src isa JL.NodeId
        next = JL.SyntaxTree(st5._graph, src)
        _orig_nodes!(next, next.source, out)
    elseif src isa Tuple
        for s in st5.source
            _orig_nodes!(st5, s, out)
        end
    end
    return out
end

# unfreeze and add "type" / "dispatch" attrs
prepare_attrs(st::JL.SyntaxTree) = let g = JL.syntax_graph(st)
    attrs = Dict(pairs(g.attributes))
    attrs[:type] = Dict{Int, Any}()
    attrs[:dispatch] = Dict{Int, String}()
    return JL.SyntaxTree(JL.SyntaxGraph(g.edge_ranges, g.edges, attrs), st._id)
end

"""
Main entrypoint
Note we are currently limited to JL-lowering and annotating types in one
operation, since the default lowerer doesn't preserve the information we need.

Evaluates the 
"""
function annotate_types(mod::Module, st0::JL.SyntaxTree,
                        @nospecialize(tt=nothing),
                        world::UInt=Base.get_world_counter())
    ctx5, st5 = jlower(mod, st0)
    st0 = prepare_attrs(st0)
    ex = JL.to_lowered_expr(mod, st5)
    @assert ex.head === :thunk && ex.args[1] isa Core.CodeInfo
    fn = Base.eval(mod, ex)
    !isa(fn, Function) && throw("Not a function")
    tt = something(tt, Base.default_tt(fn))
    mi, ci, rt = get_inferred_result(fn, tt, Base.get_world_counter())
    slottypes = ci.slottypes
    ssavaluetypes = ci.ssavaluetypes

    # Hack: We want the JL-codeinfo of the method, but we only have it of the
    # function def, which contains it.
    inner_st5_method = findfirst(c->(JS.kind(c) === JS.K"method" &&
        JS.numchildren(c) === 3 && JS.kind(c[3]) === JS.K"code_info" &&
        JS.numchildren(c[3][1]) === length(ci.code)),
                                 JS.children(st5[1]))
    inner_st5 = st5[1][inner_st5_method][3]

    sptypes = if ci.parent isa Core.MethodInstance
        Core.Compiler.sptypes_from_meth_instance(ci.parent)
    else Core.Compiler.EMPTY_SPTYPES end

    for i in eachindex(ci.ssavaluetypes)
        stmt = ci.code[i]
        if stmt isa Core.ReturnNode || stmt isa Core.GotoNode || stmt isa Core.GotoIfNot || stmt isa Core.EnterNode
            continue # control-flow has no meaningful type, so don't annotate with it
        end
        if Base.isexpr(stmt, :call)
            match_info = IOBuffer()

            argtypes = Any[
                Core.Compiler.widenconst(Core.Compiler.argextype(arg, ci, sptypes))
                for arg in stmt.args
            ]
            if !(argtypes[1] <: Core.Builtin)
                tt = Core.Compiler.argtypes_to_type(argtypes)
                f = Core.Compiler.singleton_type(argtypes[1])
                if f !== nothing
                    print(match_info, f, "(")
                    for (i, argtype) in enumerate(argtypes[2:end])
                        i == 1 || print(match_info, ", ")
                        print(match_info, "::", argtype)
                    end
                    println(match_info, ")")
                else
                    println(match_info, tt)
                end
                println(match_info, "\nDispatches to: ")

                matches = Base._methods_by_ftype(tt, #= lim =# -1, Base.get_world_counter())
                for match in matches
                    print(match_info, "  ")
                    Base.show_method(match_info, match.method)
                end
                dispatch_info = String(take!(match_info))

                if !JS.is_infix_op_call(inner_st5[1][i])
                    ssa_st = inner_st5[1][i][1]
                    orig = orig_nodes(ssa_st)
                    JL.setattr!(st0._graph, last(orig)._id; dispatch=dispatch_info)
                end
            end
        end
        ssa_st = inner_st5[1][i]
        orig = orig_nodes(ssa_st)
        for o in orig
            JL.setattr!(st0._graph, o._id; type=ci.ssavaluetypes[i])
        end
    end
    for i in eachindex(ci.slottypes)
        jl_slot::JL.Slot = inner_st5.slots[i]
        orig = orig_nodes(JL.SyntaxTree(inner_st5._graph, jl_slot.node_id))
        for o in orig
            JL.setattr!(st0._graph, o._id; type=ci.slottypes[i])
        end
    end
    st0
end
annotate_types(mod::Module, s::AbstractString, args...) = annotate_types(mod::Module, jsparse(s), args...)
# not necessary, but noting that conversion node->tree is defined
# annotate_types(mod::Module, sn0::JS.SyntaxNode, args...) = annotate_types(mod::Module, sn0, args...)

# from TypedSyntax.jl
function get_inferred_result(@nospecialize(f), @nospecialize(tt=Base.default_tt(f)),
                             world::UInt=Base.get_world_counter())
    mis = Base.method_instances(f, tt, world)
    if isempty(mis)
        sig = sprint(Base.show_tuple_as_call, Symbol(""), Base.signature_type(f, tt))
        error("no applicable type-inferred code found for ", sig)
    elseif length(mis) ≠ 1
        sig = sprint(Base.show_tuple_as_call, Symbol(""), Base.signature_type(f, tt))
        error("got $(length(mis)) possible type-inferred results for ", sig,
              ", you may need a more specialized signature")
    end
    mi = only(mis)
    ci, rt = code_typed1_by_method_instance(mi; optimize=false, debuginfo=:source)
    return mi, ci, rt
end
function code_typed1_by_method_instance(mi::Core.MethodInstance;
                                        optimize::Bool=true,
                                        debuginfo::Symbol=:default,
                                        world::UInt=Base.get_world_counter(),
                                        interp::Core.Compiler.AbstractInterpreter=Core.Compiler.NativeInterpreter(world))
    (ccall(:jl_is_in_pure_context, Bool, ()) || world == typemax(UInt)) &&
        error("code reflection should not be used from generated functions")
    debuginfo = Base.IRShow.debuginfo(debuginfo)
    code = Core.Compiler.typeinf_code(interp, mi.def::Method, mi.specTypes, mi.sparam_vals, optimize)
    rt = code.rettype
    code isa Core.CodeInfo || error("no code is available for ", mi)
    debuginfo === :none && Base.remove_linenums!(code)
    return Pair{Core.CodeInfo,Any}(code, rt)
end
