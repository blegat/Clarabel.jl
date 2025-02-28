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

    #work vectors for assembling/dissambling vectors
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
    _kkt_solve_constant_rhs!(kktsystem,data)

    return nothing
end

function _kkt_solve_constant_rhs!(
    kktsystem::DefaultKKTSystem{T},
    data::DefaultProblemData{T}
) where {T}

    kktsystem.workx .= -data.q;
    kktsolver_setrhs!(kktsystem.kktsolver, kktsystem.workx, data.b)
    kktsolver_solve!(kktsystem.kktsolver, kktsystem.x2, kktsystem.z2)

    return nothing
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
    kktsystem.workx .= -data.q
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
        #we can use the overall LHS output as
        #additional workspace for the moment
        tmp = lhs.z;
        @. tmp = rhs.z  #Don't want to modify our RHS
        cones_λ_inv_circ_op!(cones, tmp, rhs.s)                  #tmp = λ \ ds
        cones_gemv_W!(cones, :T, tmp, Wtlinvds, one(T), zero(T)) #Wᵀ(λ \ ds) = Wᵀ(tmp)
    end
    @. workz = Wtlinvds - rhs.z

    #this solves the variable part of reduced KKT system
    kktsolver_setrhs!(kktsystem.kktsolver, workx, workz)
    kktsolver_solve!(kktsystem.kktsolver,x1,z1)

    #solve for Δτ.
    #-----------
    # Numerator first
    ξ   = workx
    ξ  .= variables.x / variables.τ
    P   = Symmetric(data.P)

    tau_num = rhs.τ - rhs.κ/variables.τ + dot(data.q,x1) + dot(data.b,z1) + 2*quad_form(ξ,P,x1)

    #offset ξ for the quadratic form in the denominator
    ξ_minus_x2    = ξ   #alias to ξ, same as workx
    ξ_minus_x2  .-= x2

    tau_den  = variables.κ/variables.τ - dot(data.q,x2) - dot(data.b,z2)
    tau_den += quad_form(ξ_minus_x2,P,ξ_minus_x2) - quad_form(x2,P,x2)

    #solve for (Δx,Δz)
    #-----------
    lhs.τ  = tau_num/tau_den
    @. lhs.x = x1 + lhs.τ * x2
    @. lhs.z = z1 + lhs.τ * z2

    #solve for Δs = -Wᵀ(λ \ dₛ + WΔz) = -Wᵀ(λ \ dₛ) - WᵀWΔz
    #where the first part is already in work_conic
    #-------------
    cones_gemv_W!(cones, :N, lhs.z, workz,  one(T), zero(T))    #work = WΔz
    cones_gemv_W!(cones, :T, workz, lhs.s, -one(T), zero(T))    #Δs = -WᵀWΔz
    @. lhs.s -= Wtlinvds

    #solve for Δκ
    #--------------
    lhs.κ = -(rhs.κ + variables.κ * lhs.τ) / variables.τ

    return nothing
end
