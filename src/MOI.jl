## MOI interface for SimpleDualAscent
import MathOptInterface as MOI

MOI.Utilities.@product_of_sets(RHS, MOI.Zeros)

const OptimizerCache{T <: Real} = MOI.Utilities.GenericModel{
    T,
    MOI.Utilities.ObjectiveContainer{T},
    MOI.Utilities.VariablesContainer{T},
    MOI.Utilities.MatrixOfConstraints{T,
        MOI.Utilities.MutableSparseMatrixCSC{T, Int, MOI.Utilities.OneBasedIndexing},
        Vector{T}, RHS{T},
    },
}

mutable struct Optimizer{T} <: MOI.AbstractOptimizer
    x_primal::Dict{MOI.VariableIndex,T}
    y_dual::Dict{MOI.ConstraintIndex,T}
    zl_dual::Dict{MOI.ConstraintIndex,T}
    zu_dual::Dict{MOI.ConstraintIndex,T}
    termination_status::MOI.TerminationStatusCode
    primal_status::MOI.ResultStatusCode
    dual_status::MOI.ResultStatusCode
    settings::SDASettings
    solve_time::Float64

    function Optimizer{T}() where {T <: Real}
        return new(
            Dict{MOI.VariableIndex,T}(), Dict{MOI.ConstraintIndex,T}(), Dict{MOI.ConstraintIndex,T}(), Dict{MOI.ConstraintIndex,T}(),
            MOI.OPTIMIZE_NOT_CALLED, MOI.UNKNOWN_RESULT_STATUS, MOI.UNKNOWN_RESULT_STATUS, deepcopy(SimpleDualAscent.default_settings), 0.0,
        )
    end

    function Optimizer()
        return Optimizer{Float64}()
    end
end

function MOI.is_empty(model::Optimizer)
    return isempty(model.x_primal) && model.termination_status == MOI.OPTIMIZE_NOT_CALLED
end

function MOI.empty!(model::Optimizer)
    empty!(model.x_primal); empty!(model.y_dual); empty!(model.zl_dual); empty!(model.zu_dual); model.termination_status = MOI.OPTIMIZE_NOT_CALLED
    return
end

MOI.supports_constraint(::Optimizer{T}, ::Type{MOI.VectorAffineFunction{T}}, ::Type{MOI.Zeros}) where {T <: Real} = true
MOI.supports_constraint(::Optimizer{T}, ::Type{MOI.VariableIndex}, ::Type{MOI.GreaterThan{T}}) where {T <: Real} = true
MOI.supports_constraint(::Optimizer{T}, ::Type{MOI.VariableIndex}, ::Type{MOI.LessThan{T}}) where {T <: Real} = true
MOI.supports(::Optimizer{T}, ::MOI.ObjectiveFunction{MOI.ScalarAffineFunction{T}})  where {T <: Real} = true


function MOI.optimize!(dest::Optimizer{T}, src::MOI.ModelLike) where {T<:Real}
    cache = OptimizerCache{T}()
    index_map = MOI.copy_to(cache, src)

    @assert all(isfinite, cache.variables.lower)
    @assert all(isfinite, cache.variables.upper)

    A = convert(
        SparseArrays.SparseMatrixCSC{T,Int},
        cache.constraints.coefficients,
    )
    b = cache.constraints.constants
    b = -b # because @odow set Ax+b ∈ {0}
    c = zeros(T, size(A, 2))
    offset = cache.objective.scalar_affine.constant
    for term in cache.objective.scalar_affine.terms
        c[term.variable.value] += term.coefficient
    end
    if cache.objective.sense == MOI.MAX_SENSE
        c *= -1
    end
    l = cache.variables.lower
    u = cache.variables.upper
    x, y, zₗ, zᵤ, solve_time = solve_sda(A, b, c, l, u, dest.settings)
    for i in MOI.get(src, MOI.ListOfVariableIndices())
        dest.x_primal[i] = x[index_map[i].value]
    end
    for i in MOI.get(src, MOI.ListOfConstraintIndices{MOI.VectorAffineFunction{T},MOI.Zeros}())
        dest.y_dual[i] = y[index_map[i].value]
    end
    for i in MOI.get(src, MOI.ListOfConstraintIndices{MOI.VariableIndex,MOI.GreaterThan{T}}())
        dest.zl_dual[i] = zₗ[index_map[i].value]
    end
    for i in MOI.get(src, MOI.ListOfConstraintIndices{MOI.VariableIndex,MOI.LessThan{T}}())
        dest.zu_dual[i] = zᵤ[index_map[i].value]
    end
    dest.termination_status = MOI.OPTIMAL
    dest.primal_status = MOI.UNKNOWN_RESULT_STATUS
    dest.dual_status = MOI.FEASIBLE_POINT
    dest.solve_time = solve_time
    return index_map, false
end

MOI.get(model::Optimizer, attr::MOI.RawOptimizerAttribute) = getfield(model.settings, Symbol(attr.name))
MOI.set(model::Optimizer, attr::MOI.RawOptimizerAttribute, value) = setfield!(model.settings, Symbol(attr.name), value)

function MOI.set(model::Optimizer, ::MOI.Silent, value)
    model.settings.verbose = !value
end

MOI.get(::Optimizer{T}, ::MOI.SolverName) where {T <: Real} = T !== Float64 ? "SimpleDualAscent{$(T)}" : "SimpleDualAscent"
MOI.get(model::Optimizer, ::MOI.Silent) = !model.settings.verbose
MOI.get(model::Optimizer, ::MOI.SolveTimeSec) = model.solve_time
MOI.get(model::Optimizer, ::MOI.VariablePrimal, x::MOI.VariableIndex) = model.x_primal[x]
MOI.get(model::Optimizer{T}, ::MOI.ConstraintDual, x::MOI.ConstraintIndex{MOI.VectorAffineFunction{T},MOI.Zeros}) where {T <: Real} = model.y_dual[x]
MOI.get(model::Optimizer, ::MOI.ConstraintDual, x::MOI.ConstraintIndex{MOI.VariableIndex,MOI.GreaterThan}) = model.zl_dual[x]
MOI.get(model::Optimizer, ::MOI.ConstraintDual, x::MOI.ConstraintIndex{MOI.VariableIndex,MOI.LessThan}) = model.zu_dual[x]
MOI.get(model::Optimizer, ::MOI.ResultCount) = model.termination_status == MOI.OPTIMAL ? 1 : 0
MOI.get(model::Optimizer, ::MOI.RawStatusString) = "$(model.termination_status)"
MOI.get(model::Optimizer, ::MOI.TerminationStatus) = model.termination_status
MOI.get(model::Optimizer, ::MOI.PrimalStatus) = model.primal_status
MOI.get(model::Optimizer, ::MOI.DualStatus) = model.dual_status