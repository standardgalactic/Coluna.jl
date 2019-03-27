const SupportedObjFunc = Union{MOI.ScalarAffineFunction{Float64},
                               MOI.SingleVariable}

const SupportedVarSets = Union{MOI.Nonnegatives, 
                                MOI.Zeros,
                                MOI.Nonpositives,
                                MOI.ZeroOne,
                                MOI.Integer,
                                MOI.LessThan{Float64},
                                MOI.EqualTo{Float64},
                                MOI.GreaterThan{Float64},
                                MOI.Interval{Float64}}

const SupportedConstrFunc = Union{MOI.ScalarAffineFunction{Float64}}

const SupportedConstrSets = Union{MOI.EqualTo{Float64},
                                  MOI.GreaterThan{Float64},
                                  MOI.LessThan{Float64},
                                  MOI.Zeros}

mutable struct Optimizer <: MOI.AbstractOptimizer
    inner::Model
    # varmap::Dict{MOI.VariableIndex,Variable} ## Keys and values are created in this file
    # # add conmap here
    # constr_probidx_map::Dict{Constraint,Int}
    # var_probidx_map::Dict{Variable,Int}
    # nb_subproblems::Int
    master_factory::JuMP.OptimizerFactory
    pricing_factory::JuMP.OptimizerFactory
end

setinnermodel!(o::Optimizer, m::Model) = o.inner = m 

function Optimizer(;master_factory =
        JuMP.with_optimizer(GLPK.Optimizer), pricing_factory =
        JuMP.with_optimizer(GLPK.Optimizer), params = Params())
    model = Model(params)
    return Optimizer(model, master_factory, pricing_factory)
end

function MOI.optimize!(optimizer::Optimizer)
    optimize!(optimizer.inner)
end

function MOI.get(dest::MOIU.UniversalFallback,
        attribute::BD.ConstraintDecomposition, ci::MOI.ConstraintIndex)
    if haskey(dest.conattr, attribute)
        if haskey(dest.conattr[attribute], ci)
            return dest.conattr[attribute][ci]
        end
    end
    return ()
end

function MOI.get(dest::MOIU.UniversalFallback,
        attribute::BD.VariableDecomposition, vi::MOI.VariableIndex)
    if haskey(dest.varattr, attribute)
        if haskey(dest.varattr[attribute], vi)
            return dest.varattr[attribute][vi]
        end
    end
    return ()
end

function MOI.supports_constraint(optimizer::Optimizer, 
        ::Type{<: SupportedConstrFunc}, ::Type{<: SupportedConstrSets})
    return true
end

function MOI.supports_constraint(optimizer::Optimizer,
        ::Type{MOI.SingleVariable}, ::Type{<: SupportedVarSets})
    return true
end

function MOI.supports(optimizer::Optimizer, 
        ::MOI.ObjectiveFunction{<: SupportedObjFunc})
    return true
end

function load_obj!(vars::Vector{Variable}, m::Model,
        f::MOI.ScalarAffineFunction)
    # We need to increment values of cost_rhs with += to handle cases like $x_1 + x_2 + x_1$
    # This is safe becasue the variables are initialized with a 0.0 cost_rhs
    for term in f.terms
        coluna_var_id = m.mid2cid_map[term.variable_index].value
        setcost!(vars[coluna_var_id], term.coefficient)
    end
    return
end

function create_origvars!(vars::Vector{Variable}, m::Model, src::MOI.ModelLike, 
        copy_names::Bool)
    for m_var_id in MOI.get(src, MOI.ListOfVariableIndices())
        if copy_names
            name = MOI.get(src, MOI.VariableName(), m_var_id)
        else
            name = string("var_", m_var_id.value)
        end
        var = Variable(m, name)
        push!(vars, var)
        c_var_id = MOI.VariableIndex(getuid(var))
        m.mid2cid_map[m_var_id] = c_var_id
    end
    return
end

function create_origconstr!(constrs, memberships, vars, 
        model, name, f::MOI.SingleVariable, s, m_constr_id)
    c_var_id = model.mid2cid_map[f.variable].value
    set!(vars[c_var_id], s)
    return
end

function create_origconstr!(constrs, memberships::Vector{VarMembership}, vars, 
        model, name, f::MOI.ScalarAffineFunction, s, m_constr_id)
    constr = Constraint(model, name)
    set!(constr, s)
    push!(constrs, constr)
    membership = VarMembership() #spzeros(Float64, MAX_SV_ENTRIES)
    for term in f.terms
        c_var_id = model.mid2cid_map[term.variable_index].value
        add!(membership,c_var_id, term.coefficient)
    end
    push!(memberships, membership)
    c_constr_id = MOI.ConstraintIndex{typeof(f),typeof(s)}(getuid(constr))
    model.mid2cid_map[m_constr_id] = c_constr_id
    return
end

function create_origconstrs!(constrs::Vector{Constraint}, 
        memberships::Vector{VarMembership}, m::Model, src::MOI.ModelLike, 
        vars::Vector{Variable}, copy_names::Bool)
    for (F, S) in MOI.get(src, MOI.ListOfConstraints())
        for m_constr_id in MOI.get(src, MOI.ListOfConstraintIndices{F, S}())
            if copy_names
                name = MOI.get(src, MOI.ConstraintName(), m_constr_id)
            else
                name = string("constr_", m_constr_id.value)
            end
            f = MOI.get(src, MOI.ConstraintFunction(), m_constr_id)
            s = MOI.get(src, MOI.ConstraintSet(), m_constr_id)
            create_origconstr!(constrs, memberships, vars, m, name, f, s, m_constr_id)
        end
    end
    return
end

function create_original_formulation!(model, vars, constrs, memberships::Vector{VarMembership}, 
        min_sense::Bool)
    orig_form = get_original_formulation(model)
    add!(orig_form, vars)
    add!(orig_form, constrs, memberships)
    register_objective_sense!(orig_form, min_sense)
    return
end

function register_original_formulation!(model::Model, dest::Optimizer, src::MOI.ModelLike, copy_names)
    orig_form = Formulation(model, src)
    set_original_formulation!(model, orig_form)

    vars = Variable[]
    create_origvars!(vars, model, src, copy_names)

    constrs = Constraint[]
    memberships = Vector{VarMembership}()
    create_origconstrs!(constrs, memberships, model, src, vars, copy_names)

    obj = MOI.get(src, MOI.ObjectiveFunction{MOI.ScalarAffineFunction{Float64}}())
    load_obj!(vars, model, obj)

    sense = MOI.get(src, MOI.ObjectiveSense())
    min_sense = (sense == MOI.MIN_SENSE)
    create_original_formulation!(model, vars, constrs, memberships, min_sense)
    return
end

function load_decomposition_annotations!(m::Model, src::MOI.ModelLike)
    for (m_id, c_id) in m.mid2cid_map.conmap
        m.constr_annotations[c_id.value] = MOI.get(src, BD.ConstraintDecomposition(), m_id)
    end
    for (m_id, c_id) in m.mid2cid_map.varmap
        m.var_annotations[c_id.value] = MOI.get(src, BD.VariableDecomposition(), m_id)
    end
    return
end

function MOI.copy_to(dest::Optimizer, src::MOI.ModelLike; copy_names=true)
    model = dest.inner
    set_optimizers_dict(dest)
    register_original_formulation!(model, dest, src, copy_names)

    # Retrieve annotation
    load_decomposition_annotations!(model, src)
    return model.mid2cid_map
end

function set_optimizers_dict(dest::Optimizer)
    @warn "To be updated"
    # set coluna optimizers
    # model = dest.inner
    # master_problem = model.extended_problem.master_problem
    # model.problemidx_optimizer_map[master_problem.prob_ref] =
    #         dest.master_factory()
    # for subprobidx in 1:dest.nb_subproblems
    #     pricingprob = model.extended_problem.pricing_vect[subprobidx]
    #     model.problemidx_optimizer_map[pricingprob.prob_ref] =
    #             dest.pricing_factory()
    # end
end

function MOI.empty!(optimizer::Optimizer)
    optimizer.inner.re_formulation = nothing
end

# ######################
# ### Get functions ####
# ######################

MOI.is_empty(optimizer::Optimizer) = (optimizer.inner.re_formulation == nothing)

# function MOI.get(coluna_optimizer::Optimizer, object::MOI.ObjectiveBound)
#     return coluna_optimizer.inner.extended_problem.dual_inc_bound
# end

# function MOI.get(coluna_optimizer::Optimizer, object::MOI.ObjectiveValue)
#     return coluna_optimizer.inner.extended_problem.primal_inc_bound
# end

# function get_coluna_var_val(coluna_optimizer::Optimizer, sp_var::SubprobVar)
#     solution = coluna_optimizer.inner.extended_problem.solution.var_val_map
#     sp_var_val = 0.0
#     for (var,val) in solution
#         if isa(var, MasterVar)
#             continue
#         end
#         if haskey(var.solution.var_val_map, sp_var)
#             sp_var_val += val*var.solution.var_val_map[sp_var]
#         end
#     end
#     return sp_var_val
# end

# function get_coluna_var_val(coluna_optimizer::Optimizer, var::MasterVar)
#     solution = coluna_optimizer.inner.extended_problem.solution
#     if haskey(solution.var_val_map, var)
#         return solution.var_val_map[var]
#     else
#         return 0.0
#     end
# end

# function MOI.get(coluna_optimizer::Optimizer,
#                  object::MOI.VariablePrimal, ref::MOI.VariableIndex)
#     var = coluna_optimizer.varmap[ref] # This gets a coluna variable
#     return get_coluna_var_val(coluna_optimizer, var)
# end

# function MOI.get(coluna_optimizer::Optimizer,
#                  object::MOI.VariablePrimal, ref::Vector{MOI.VariableIndex})
#     return [MOI.get(coluna_optimizer, object, ref[i]) for i in 1:length(ref)]
# end
