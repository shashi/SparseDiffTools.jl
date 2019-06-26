istainted(ctx, x) = ismetatype(x, ctx, ProvinanceSet)

# Must return 5 exprs
function rewrite_branch(ctx, stmt, extraslot, i)
    # turn
    #   gotoifnot %p #g 
    # into
    #   %t = %p isa Tainted
    #   gotoifnot %t #orig
    #   %rec = this_here_predicate!(path)
    #   gotoifnot %rec #orig+1 (the next statement after gotoifnot)

    exprs = Any[]
    cond = stmt.args[1]        # already an SSAValue

    # insert a check to see if SSAValue(i) isa Tainted
    istainted_ssa = Core.SSAValue(i)
    push!(exprs, :($(Expr(:nooverdub, istainted))($(Expr(:contextslot)), $cond)))

    # not tainted? jump to the penultimate statement
    push!(exprs, Expr(:gotoifnot, istainted_ssa, i+5))

    # tainted? then use this_here_predicate!(SSAValue(1))
    current_pred = i+2
    push!(exprs, :($(Expr(:nooverdub, this_here_predicate!))()))

    # Store the interpreter-provided predicate in the slot
    push!(exprs, Expr(:(=), extraslot, SSAValue(i+2)))

    push!(exprs, Core.GotoNode(i+6))

    push!(exprs, Expr(:(=), extraslot, cond))

    # here we put in the original code
    stmt1 = copy(stmt)
    stmt.args[1] = extraslot
    push!(exprs, stmt)

    exprs
end

function rewrite_tainted_branches(ctx, ref)
    rewrite_ir(ctx, ref.code_info)
end

function insertat!(j, code, codelocs, exprs)
    if exprs isa Expr
        exprs = [exprs]
    end
    n = length(exprs) + 1
    Cassette.insert_statements!(code, codelocs,
        (stmt, i) -> i==j ? n : nothing,
        (stmt, i) -> vcat(exprs, stmt))
end

function rewrite_ir(ctx, ir)
    # turn
    #   <val> ? t : f
    # into
    #   <val> isa Tainted ? this_here_predicate!(p) : <val> ? t : f

    ir = copy(ir)

    extraslot = gensym("tmp")
    push!(ir.slotnames, extraslot)
    push!(ir.slotflags, 0x00)
    extraslot = Core.SlotNumber(length(ir.slotnames))

    Cassette.insert_statements!(ir.code, ir.codelocs,
        (stmt, i) -> Base.Meta.isexpr(stmt, :gotoifnot) ? 7 : nothing, 
        (stmt, i) -> rewrite_branch(ctx, stmt, extraslot, i))

    ir.ssavaluetypes = length(ir.code)
    # Core.Compiler.validate_code(ir)
    return ir
end
const BranchesPass = Cassette.@pass rewrite_tainted_branches

# Some nooverdubs:
function Cassette.overdub(ctx::SparsityContext, f::typeof(istainted), args...)
    Cassette.fallback(ctx, f, args...)
end

function Cassette.overdub(ctx::SparsityContext, f::typeof(this_here_predicate!))
    this_here_predicate!(ctx)
end