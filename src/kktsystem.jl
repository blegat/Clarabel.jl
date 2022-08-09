# ---------------
# KKT System
# ---------------

mutable struct DefaultKKTSystem{T} <: AbstractKKTSystem{T}

    #the KKT system solver
    kktsolver::AbstractKKTSolver{T}

    #solution vector for constant part of KKT solves
    x1::Vector{T}
    z1::Vector{T}

    #solution vector for general KKT solves
    x2::Vector{T}
    z2::Vector{T}

    #work vectors for assembling/disassembling vectors
    workx::Vector{T}
    workz::ConicVector{T}
    work_conic::ConicVector{T}

        function DefaultKKTSystem{T}(
            data::DefaultProblemData{T},
            cones::ConeSet{T},
            settings::Settings{T}
        ) where {T}

        #basic problem dimensions
        (m, n) = (data.m, data.n)

        #create the linear solver.  Always LDL for now
        kktsolver = DirectLDLKKTSolver{T}(data.P,data.A,cones,m,n,settings)

        #the LHS constant part of the reduced solve
        x1   = Vector{T}(undef,n)
        z1   = Vector{T}(undef,m)

        #the LHS for other solves
        x2   = Vector{T}(undef,n)
        z2   = Vector{T}(undef,m)

        #workspace compatible with (x,z)
        workx   = Vector{T}(undef,n)
        workz   = ConicVector{T}(cones)

        #additional conic workspace vector compatible with s and z
        work_conic = ConicVector{T}(cones)

        return new(kktsolver,x1,z1,x2,z2,workx,workz,work_conic)

    end

end

DefaultKKTSystem(args...) = DefaultKKTSystem{DefaultFloat}(args...)

function kkt_update!(
    kktsystem::DefaultKKTSystem{T},
    data::DefaultProblemData{T},
    cones::ConeSet{T}
) where {T}

    #update the linear solver with new cones
    kktsolver_update!(kktsystem.kktsolver,cones)

    #calculate KKT solution for constant terms
    # YC: kkt_constant_status for checking numerical stability
    kkt_constant_status = _kkt_solve_constant_rhs!(kktsystem,data)

    return kkt_constant_status
end

function _kkt_solve_constant_rhs!(
    kktsystem::DefaultKKTSystem{T},
    data::DefaultProblemData{T}
) where {T}

    @. kktsystem.workx = -data.q;

    kktsolver_setrhs!(kktsystem.kktsolver, kktsystem.workx, data.b)
    kktsolver_solve!(kktsystem.kktsolver, kktsystem.x2, kktsystem.z2)

    return any(isnan,kktsystem.x2) || any(isnan, kktsystem.z2)
end


function kkt_solve_initial_point!(
    kktsystem::DefaultKKTSystem{T},
    variables::DefaultVariables{T},
    data::DefaultProblemData{T}
) where{T}

    # solve with [0;b] as a RHS to get (x,s) initializers
    # zero out any sparse cone variables at end
    kktsystem.workx .= zero(T)
    kktsystem.workz .= data.b
    kktsolver_setrhs!(kktsystem.kktsolver, kktsystem.workx, kktsystem.workz)
    kktsolver_solve!(kktsystem.kktsolver, variables.x, variables.s)

    # solve with [-q;0] as a RHS to get z initializer
    # zero out any sparse cone variables at end
    @. kktsystem.workx = -data.q
    kktsystem.workz .=  zero(T)

    kktsolver_setrhs!(kktsystem.kktsolver, kktsystem.workx, kktsystem.workz)
    kktsolver_solve!(kktsystem.kktsolver, nothing, variables.z)

    return nothing
end


function kkt_solve!(
    kktsystem::DefaultKKTSystem{T},
    lhs::DefaultVariables{T},
    rhs::DefaultVariables{T},
    data::DefaultProblemData{T},
    variables::DefaultVariables{T},
    cones::ConeSet{T},
    steptype::Symbol   #:affine or :combined
) where{T}

    (x1,z1) = (kktsystem.x1, kktsystem.z1)
    (x2,z2) = (kktsystem.x2, kktsystem.z2)
    (workx,workz) = (kktsystem.workx, kktsystem.workz)

    #solve for (x1,z1)
    #-----------
    @. workx = rhs.x

    #compute Wᵀ(λ \ ds), with shortcut in affine case
    Wtlinvds = kktsystem.work_conic

    if steptype == :affine
        @. Wtlinvds = variables.s

    else  #:combined expected, but any general RHS should do this
        #we can use the overall LHS output as additional workspace for the moment

        # compute the generalized step of Wᵀ(λ \ ds), where Wᵀ(λ \ ds) is set to ds for unsymmetric cones
        cones_Wt_λ_inv_circ_ds!(cones,lhs.z,rhs.z,rhs.s,Wtlinvds)
    end

    @. workz = Wtlinvds - rhs.z


    #####################################################
    #this solves the variable part of reduced KKT system
    kktsolver_setrhs!(kktsystem.kktsolver, workx, workz)
    kktsolver_solve!(kktsystem.kktsolver,x1,z1)

    #solve for Δτ.
    #-----------
    # Numerator first
    ξ   = workx
    @. ξ = variables.x / variables.τ

    P   = Symmetric(data.P)

    tau_num = rhs.τ - rhs.κ/variables.τ + dot(data.q,x1) + dot(data.b,z1) + 2*quad_form(ξ,P,x1)

    #offset ξ for the quadratic form in the denominator
    ξ_minus_x2    = ξ   #alias to ξ, same as workx
    @. ξ_minus_x2  -= x2

    tau_den  = variables.κ/variables.τ - dot(data.q,x2) - dot(data.b,z2)
    tau_den += quad_form(ξ_minus_x2,P,ξ_minus_x2) - quad_form(x2,P,x2)

    #solve for (Δx,Δz)
    #-----------
    lhs.τ  = tau_num/tau_den
    @. lhs.x = x1 + lhs.τ * x2
    @. lhs.z = z1 + lhs.τ * z2


    #####################################################
    # # asymmetric system solver
    # m,n = size(data.A)
    # ξ = variables.x/variables.τ

    # rhs_asym = vcat(rhs.x, workz.vec, [rhs.τ - rhs.κ/variables.τ])
    # lhs_asym = Vector{T}(undef, m+n+1)
    # K_tmp = hcat(kktsystem.kktsolver.ldlsolver.KKTsym, [data.q; -data.b])
    # K_asym = vcat(K_tmp, [-(2*data.P*ξ + data.q)' -data.b' dot(ξ,data.P,ξ) + T(1e-8)])

    # F = lu(K_asym)
    # # F = qr(K_asym)

    # lhs_asym = F\rhs_asym
    # mul!(rhs_asym,K_asym,lhs_asym,-1.,1.)

    # norme = norm(rhs_asym,Inf)

    # @. lhs.x =  lhs_asym[1:n]
    # @. lhs.z.vec = lhs_asym[n+1:m+n]
    # lhs.τ  = lhs_asym[m+n+1]

    # # one iterative refinement
    # if norme > T(1e-10)
    #     lhs_asym = F\rhs_asym
    #     mul!(rhs_asym,K_asym,lhs_asym,-1.,1.)
    #     norme = norm(rhs_asym,Inf)

    #     @. lhs.x +=  lhs_asym[1:n]
    #     @. lhs.z.vec += lhs_asym[n+1:m+n]
    #     lhs.τ  += lhs_asym[m+n+1]

    #     println("current IR: ", norme)
    # end
    



    #solve for Δs = -Wᵀ(λ \ dₛ + WΔz) = -Wᵀ(λ \ dₛ) - WᵀWΔz
    #where the first part is already in Wtlinvds
    #-------------
    # compute the generalized step of -WᵀWΔz, where -WᵀW is set to -μH(z) for unsymmetric cones
    cones_WtW_Δz!(cones,lhs.z,lhs.s,workz)

    @. lhs.s -= Wtlinvds

    #solve for Δκ
    #--------------
    lhs.κ = -(rhs.κ + variables.κ * lhs.τ) / variables.τ

    return nothing
end
