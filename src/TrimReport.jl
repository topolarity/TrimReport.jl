module TrimReport

using JuliaSyntax
using JuliaLowering
using JSON

const JS = JuliaSyntax
const JL = JuliaLowering

jsparse(s) = JS.build_tree(JL.SyntaxTree, JS.parse!(JS.ParseStream(s); rule=:statement))

function jlower(mod, st0)
    ctx1, st1 = JL.expand_forms_1(  mod,  st0)
    ctx2, st2 = JL.expand_forms_2(  ctx1, st1)
    ctx3, st3 = JL.resolve_scopes(  ctx2, st2)
    ctx4, st4 = JL.convert_closures(ctx3, st3)
    ctx5, st5 = JL.linearize_ir(    ctx4, st4)
    return ctx5, st5
end

include("annotate.jl")

export jsparse, jlower

function write_annotated(filename::String, mod::Module, code::String)
    tree = jsparse(code)

    # We could try to use JuliaSyntaxHighlighting here, but to be honest, despite
    # the AST / parser being much more accurate, the highlighting is not quite as
    # pretty as the built-in support from shikijs and it doesn't work anyway for
    # partially Julian output, such as stacktraces, etc.

    # eval's the method definition and then adds the 'type' / 'dispatch' attributes
    # to the SyntaxTree
    typed_tree = annotate_types(mod, tree)
    display(typed_tree)

    annotations = Tuple{UnitRange{Int}, Tuple{Int,Int}, Any}[]

    delta = 0
    offsets = Tuple{Int,Int}[(0,0)]
    for (codeunit_i, ch) in pairs(code)
        # If the character is more than 1 codeunit wide, then the
        # delta between the codeunit versus character increases
        if ncodeunits(ch) > 1
            delta += ncodeunits(ch) - 1
            push!(offsets, (codeunit_i, -delta))
        end
    end
    to_char(cu) = cu + offsets[findlast(x->x[1]<(cu), offsets)][2]

    # We need to emit span + type information to add to the output
    worklist = Any[typed_tree]
    while !isempty(worklist)
        item = pop!(worklist)

        # infix calls don't have precise source information for the (possibly multiple)
        # appearances of their operator, and anyway the type information can be a bit
        # distracting, so we exclude the operator here
        if item.kind === JS.K"call" && JS.is_infix_op_call(item)
            children = JS.children(item)
            for (i, child) in enumerate(children)
                i == 2 && continue
                push!(worklist, child)
            end
            continue
        end

        if hasproperty(item, :dispatch)
            cu_range = JS.char_range(item.source)
            char_range = to_char(first(cu_range)):to_char(last(cu_range))
            push!(annotations, (char_range, JS.source_location(item.source), item.dispatch))
        elseif hasproperty(item, :type)
            if item.kind === JS.K"Identifier"
                cu_range = JS.char_range(item.source)
                char_range = to_char(first(cu_range)):to_char(last(cu_range))
                push!(annotations, (char_range, JS.source_location(item.source), item.type))
            end
        end

        append!(worklist, JS.children(item))
    end

    open(filename, "w") do f
        # Copy the header
        write(f, read(joinpath(@__DIR__, "header.html")))

        # Print the code
        println(f, "const source = `")
        println(f, code)
        println(f, "`")

        # Add the type annotations (+ warnings / errors)
        println(f, "const nodes = [")
        for (span, srcloc, type) in annotations
            println(f, """
               {
                 line: $(srcloc[1]),
                 character: $(srcloc[2] - 1),
                 start: $(first(span)),
                 length: $(length(span)),
                 type: 'hover',
                 target: '',
                 text: $(type === nothing ? "undefined" : "`$type`"),
                 docs: undefined, // TODO
               },
            """)
        end
        println(f, "]")

        # Copy the footer
        write(f, read(joinpath(@__DIR__, "footer.html")))
    end

    return nothing
end

export write_annotated

end # module TrimReport
