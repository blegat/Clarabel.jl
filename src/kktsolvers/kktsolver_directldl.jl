# -------------------------------------
# KKTSolver using direct LDL factorisation
# -------------------------------------

mutable struct DirectLDLKKTSolver{T} <: AbstractKKTSolver{T}

    # problem dimensions
    m::Int; n::Int; p::Int

    # Left and right hand sides for solves
    x::Vector{T}
    b::Vector{T}

    # internal workspace for IR scheme
    work_e::Vector{T}
    work_dx::Vector{T}

    #KKT mapping from problem data to KKT
    map::LDLDataMap

    #the expected signs of D in KKT = LDL^T
    Dsigns::Vector{Int}

    # a vector for storing the WtW blocks
    # on the in the KKT matrix block diagonal
    WtWblocks::Vector{Vector{T}}

    #unpermuted KKT matrix
    KKT::SparseMatrixCSC{T,Int}

    #symmetric view for residual calcs
    KKTsym::Symmetric{T, SparseMatrixCSC{T,Int}}

    #settings just points back to the main solver settings.
    #Required since there is no separate LDL settings container
    settings::Settings{T}

    #the direct linear LDL solver
    ldlsolver::AbstractDirectLDLSolver{T}

    function DirectLDLKKTSolver{T}(P,A,cones,m,n,settings) where {T}

        #solving in sparse format.  Need this many
        #extra variables for SOCs
        p = 2*cones.type_counts[SecondOrderConeT]

        #LHS/RHS/work for iterative refinement
        x    = Vector{T}(undef,n+m+p)
        b    = Vector{T}(undef,n+m+p)
        work_e  = Vector{T}(undef,n+m+p)
        work_dx = Vector{T}(undef,n+m+p)

        #the expected signs of D in LDL
        Dsigns = Vector{Int}(undef,n+m+p)
        _fill_Dsigns!(Dsigns,m,n,p)

        #updates to the diagonal of KKT will be
        #assigned here before updating matrix entries
        WtWblocks = _allocate_kkt_WtW_blocks(T, cones)

        #which LDL solver should I use?
        ldlsolverT = _get_ldlsolver_type(settings.direct_solve_method)

        #does it want a :triu or :tril KKT matrix?
        kktshape = required_matrix_shape(ldlsolverT)
        KKT, map = _assemble_kkt_matrix(P,A,cones,kktshape)

        if(settings.static_regularization_enable)
            ϵ = settings.static_regularization_eps
            @views _offset_values_KKT!(KKT, map.diag_full[1:n], ϵ, Dsigns[1:n])
        end

        #KKT will be triu data only, but we will want
        #the following to allow products like KKT*x
        KKTsym = Symmetric(KKT)

        #the LDL linear solver engine
        ldlsolver = ldlsolverT{T}(KKT,Dsigns,settings)

        return new(m,n,p,x,b,work_e,work_dx,map,Dsigns,WtWblocks,KKT,KKTsym,settings,ldlsolver)
    end

end

DirectLDLKKTSolver(args...) = DirectLDLKKTSolver{DefaultFloat}(args...)

function _get_ldlsolver_type(s::Symbol)
    try
        return DirectLDLSolversDict[s]
    catch
        throw(error("Unsupported direct LDL linear solver :", s))
    end
end

function _fill_Dsigns!(Dsigns,m,n,p)

    Dsigns .= 1

    #flip expected negative signs of D in LDL
    Dsigns[n+1:n+m] .= -1

    #the trailing block of p entries should
    #have alternating signs
    Dsigns[(n+m+1):2:(n+m+p)] .= -1
end

#update entries in the kktsolver object using the
#given index into its CSC representation
function _update_values!(
    ldlsolver::AbstractDirectLDLSolver{T},
    KKT::SparseMatrixCSC{T,Ti},
    index::Vector{Ti},
    values::Vector{T}
) where{T,Ti}

    #Update values in the KKT matrix K
    _update_values_KKT!(KKT,index,values)

    #give the LDL subsolver an opportunity to update the same
    #values if needed.   This latter is useful for QDLDL
    #since it stores its own permuted copy
    update_values!(ldlsolver,index,values)

end

#updates KKT matrix values
function _update_values_KKT!(
    KKT::SparseMatrixCSC{T,Int},
    index::Vector{Ti},
    values::Vector{T}
) where{T,Ti}

    #Update values in the KKT matrix K
    @. KKT.nzval[index] = values

end

#scale entries in the kktsolver object using the
#given index into its CSC representation
function _scale_values!(
    ldlsolver::AbstractDirectLDLSolver{T},
    KKT::SparseMatrixCSC{T,Ti},
    index::Vector{Ti},
    scale::T
) where{T,Ti}

    #Update values in the KKT matrix K
    _scale_values_KKT!(KKT,index,scale)

    #give the LDL subsolver an opportunity to update the same
    #values if needed.   This latter is useful for QDLDL
    #since it stores its own permuted copy
    scale_values!(ldlsolver,index,scale)

end

#updates KKT matrix values
function _scale_values_KKT!(
    KKT::SparseMatrixCSC{T,Int},
    index::Vector{Ti},
    scale::T
) where{T,Ti}

    #Update values in the KKT matrix K
    @. KKT.nzval[index] *= scale

end




#offset entries in the kktsolver object using the
#given index into its CSC representation.  Lengths
#of index and signs must agree
function _offset_values!(
    ldlsolver::AbstractDirectLDLSolver{T},
    KKT::SparseMatrixCSC{T,Ti},
    index::AbstractVector{Ti},
    offset::T,
    signs::AbstractVector{<:Integer}
) where{T,Ti}

    #Update values in the KKT matrix K
    _offset_values_KKT!(KKT, index, offset, signs)

    # ...and in the LDL subsolver if needed.
    offset_values!(ldlsolver, index, offset, signs)

end

#offsets KKT matrix values
function _offset_values_KKT!(
    KKT::SparseMatrixCSC{T,Ti},
    index::AbstractVector{Ti},
    offset::T,
    signs::AbstractVector{<:Integer}  #allows Vector{T} or a @view
) where{T,Ti}

    #Update values in the KKT matrix K
    @. KKT.nzval[index] += offset*signs

end

function kktsolver_update!(
    kktsolver::DirectLDLKKTSolver{T},
    cones::ConeSet{T}
) where {T}

    # the kkt update function is slow if we apply repeated
    # dynamic dispatch on the abstract ldlsolver.  We
    # therefore make an inner function that will compile
    # to a conrete implemention for whatever ldlsolver we have
    # here
    ldlsolver = kktsolver.ldlsolver
    _kktsolver_update_inner!(kktsolver,ldlsolver,cones)
end



function _kktsolver_update_inner!(
    kktsolver::DirectLDLKKTSolver{T},
    ldlsolver::AbstractDirectLDLSolver{T},
    cones::ConeSet{T}
) where {T}

    settings  = kktsolver.settings
    map       = kktsolver.map
    KKT       = kktsolver.KKT


    #Set the elements the W^tW blocks in the KKT matrix.
    cones_get_WtW_blocks!(cones,kktsolver.WtWblocks)
    for (index, values) in zip(map.WtWblocks,kktsolver.WtWblocks)
        #change signs to get -W^TW
        values .= -values
        _update_values!(ldlsolver,KKT,index,values)
    end

    #update the scaled u and v columns.
    cidx = 1        #which of the SOCs are we working on?

    for (i,K) = enumerate(cones)
        if isa(cones.cone_specs[i],SecondOrderConeT)

                η2 = K.η^2

                #off diagonal columns (or rows)
                _update_values!(ldlsolver,KKT,map.SOC_u[cidx],K.u)
                _update_values!(ldlsolver,KKT,map.SOC_v[cidx],K.v)
                _scale_values!(ldlsolver,KKT,map.SOC_u[cidx],-η2)
                _scale_values!(ldlsolver,KKT,map.SOC_v[cidx],-η2)


                #add η^2*(1/-1) to diagonal in the extended rows/cols
                _update_values!(ldlsolver,KKT,[map.SOC_D[cidx*2-1]],[-η2])
                _update_values!(ldlsolver,KKT,[map.SOC_D[cidx*2  ]],[+η2])

                cidx += 1
        end

    end

    #Perturb the diagonal terms WtW that we have just overwritten
    #with static regularizers.  Note that we don't want to shift
    #elements in the ULHS (corresponding to P) since we already
    #shifted them at initialization and haven't overwritten that block
    if(settings.static_regularization_enable)
        ϵ = settings.static_regularization_eps
        (m,n,p) = (kktsolver.m,kktsolver.n,kktsolver.p)
        @views _offset_values!(ldlsolver,KKT, map.diag_full[(n+1):(m+n+p)], ϵ, kktsolver.Dsigns[(n+1):(m+n+p)])
    end

    #refactor with new data
    refactor!(ldlsolver,kktsolver.KKT)

    return nothing
end


function kktsolver_setrhs!(
    kktsolver::DirectLDLKKTSolver{T},
    rhsx::AbstractVector{T},
    rhsz::AbstractVector{T}
) where {T}

    b = kktsolver.b
    (m,n,p) = (kktsolver.m,kktsolver.n,kktsolver.p)

    b[1:n]             .= rhsx
    b[(n+1):(n+m)]     .= rhsz
    b[(n+m+1):(n+m+p)] .= 0

    return nothing
end


function kktsolver_getlhs!(
    kktsolver::DirectLDLKKTSolver{T},
    lhsx::Union{Nothing,AbstractVector{T}},
    lhsz::Union{Nothing,AbstractVector{T}}
) where {T}

    x = kktsolver.x
    (m,n,p) = (kktsolver.m,kktsolver.n,kktsolver.p)

    isnothing(lhsx) || (lhsx .= x[1:n])
    isnothing(lhsz) || (lhsz .= x[(n+1):(n+m)])

    return nothing
end


function kktsolver_solve!(
    kktsolver::DirectLDLKKTSolver{T},
    lhsx::Union{Nothing,AbstractVector{T}},
    lhsz::Union{Nothing,AbstractVector{T}}
) where {T}

    (x,b) = (kktsolver.x,kktsolver.b)
    solve!(kktsolver.ldlsolver,x,b)

    if(kktsolver.settings.iterative_refinement_enable)
        iterative_refinement(kktsolver)
    end

    kktsolver_getlhs!(kktsolver,lhsx,lhsz)

    return nothing
end

function iterative_refinement(kktsolver::DirectLDLKKTSolver{T}) where{T}

    (x,b)   = (kktsolver.x,kktsolver.b)
    (e,dx)  = (kktsolver.work_e, kktsolver.work_dx)
    settings = kktsolver.settings

    #iterative refinement params
    IR_reltol    = settings.iterative_refinement_reltol
    IR_abstol    = settings.iterative_refinement_abstol
    IR_maxiter   = settings.iterative_refinement_max_iter
    IR_stopratio = settings.iterative_refinement_stop_ratio

    if(settings.static_regularization_enable)
        ϵ = settings.static_regularization_eps
    else
        ϵ = zero(settings.static_regularization_eps)
    end

    #Note that K is only triu data, so need to
    #be careful when computing the residual
    K      = kktsolver.KKT
    KKTsym = kktsolver.KKTsym
    normb  = norm(b,Inf)

    #compute the initial error
    norme = _get_refine_error!(e,b,KKTsym,kktsolver.Dsigns,ϵ,x)

    for i = 1:IR_maxiter

        if(norme <= IR_abstol + IR_reltol*normb)
            # within tolerance.  Exit
            return nothing
        end

        lastnorme = norme

        #make a refinement and continue
        solve!(kktsolver.ldlsolver,dx,e)

        #prospective solution is x + dx.   Use dx space to
        #hold it for a check before applying to x
        ξ = dx
        @. ξ += x
        norme = _get_refine_error!(e,b,KKTsym,kktsolver.Dsigns,ϵ,ξ)

        if(lastnorme/norme < IR_stopratio)
            #insufficient improvement.  Exit
            return nothing
        else
            @. x .= ξ  #PJG: pointer swap might be faster
        end
    end

    return nothing
end


# computes e = b - (K+ϵD)ξ + ϵDξ, overwriting the first argument
# and returning its norm

function _get_refine_error!(e,b,KKTsym,D,ϵ,ξ)

    e .= b
    mul!(e,KKTsym,ξ,-1.,1.)   # e = b - Kξ

    if(!iszero(ϵ))
        @. e += ϵ * D * ξ
    end

    return norm(e,Inf)

end
