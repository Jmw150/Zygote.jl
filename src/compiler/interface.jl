using InteractiveUtils
using InteractiveUtils: typesof
using Core: Typeof
import Base: copy!, IdSet
import Base.Broadcast: broadcasted, materialize!

mutable struct Context <: AContext
  cache::Union{IdDict{Any,Any},Nothing}
end

Context() = Context(nothing)

cache(cx::Context) = cx.cache === nothing ? (cx.cache = IdDict()) : cx.cache

struct Pullback{S,T}
  t::T
end

Pullback{S}(x) where S = Pullback{S,typeof(x)}(x)

struct CompileError
  T
  e
end

function Base.showerror(io::IO, e::CompileError)
  print(io, "Compiling $(e.T): ")
  showerror(io, e.e)
end

# interface2.jl

# Wrappers
_pullback(f, args...) = _pullback(Context(), f, args...)

tailmemaybe(::Nothing) = nothing
tailmemaybe(x::Tuple) = Base.tail(x)

function pullback(f, args...)
  y, back = _pullback(f, args...)
  y, Δ -> tailmemaybe(back(Δ))
end

sensitivity(y::Number) = one(y)
sensitivity(y::Complex) = error("Output is complex, so the gradient is not defined.")
sensitivity(y::AbstractArray) = error("Output is an array, so the gradient is not defined. Perhaps you wanted jacobian.")
sensitivity(y) = error("Output should be scalar; gradients are not defined for output $(repr(y))")

"""
    gradient(f, args...)

Returns a tuple containing `∂f/∂x` for each argument `x`,
the derivative (for scalar `x`) or the gradient.

`f(args...)` must be a real number, see [`jacobian`](@ref) for array output.

See also [`withgradient`](@ref) to keep the value `f(args...)`,
and [`pullback`](@ref) for value and back-propagator.

```jldoctest; setup=:(using Zygote)
julia> gradient(*, 2.0, 3.0, 5.0)
(15.0, 10.0, 6.0)

julia> gradient(x -> sum(abs2,x), [7.0, 11.0, 13.0])
([14.0, 22.0, 26.0],)

julia> gradient([7, 11], 0, 1) do x, y, d
         p = size(x, d)
         sum(x.^p .+ y)
       end
([14.0, 22.0], 2.0, nothing)
```
"""
function gradient(f, args...)
  y, back = pullback(f, args...)
  grad = back(sensitivity(y))
  isnothing(grad) ? nothing : map(_project, args, grad)
end

# Base.adjoint(f::Function) = x -> gradient(f, x)[1]  # piracy!
Base.adjoint(f::Function) = x -> begin  # still piracy! avoids projection for legacy reasons
  y, back = pullback(f, x)
  back(sensitivity(y))[1]
end

"""
    withgradient(f, args...)
    withgradient(f, ::Params)

Returns both the value of the function and the [`gradient`](@ref),
as a named tuple. 

```jldoctest; setup=:(using Zygote)
julia> y, ∇ = withgradient(/, 1, 2)
(val = 0.5, grad = (0.5, -0.25))

julia> ∇ == gradient(/, 1, 2)
true
```
"""
function withgradient(f, args...)
  y, back = pullback(f, args...)
  grad = back(sensitivity(y))
  results = isnothing(grad) ? map(_ -> nothing, args) : map(_project, args, grad)
  (val=y, grad=results)
end

# Param-style wrappers

"""
    gradient(() -> loss(), ps::Params) -> Grads

Gradient with implicit parameters. Takes a zero-argument function,
and returns a dictionary-like container, whose keys are arrays `x in ps`.

```jldoctest; setup=:(using Zygote)
julia> x = [1 2 3; 4 5 6]; y = [7, 8]; z = [1, 10, 100];

julia> g = gradient(Params([x, y])) do
         sum(x .* y .* z')
       end
Grads(...)

julia> g[x]
2×3 Matrix{Float64}:
 7.0  70.0  700.0
 8.0  80.0  800.0

julia> haskey(g, z)  # only x and y are parameters
false
```
"""
gradient

"""
    Params([A, B])

Container for implicit parameters, used when differentiating
a zero-argument funtion `() -> loss(A, B)` with respect to `A, B`.
"""
struct Params{B <: Buffer}
  order::B
  params::IdSet{Any} # TODO store ids only
end

Params() = Params(Buffer([], false), IdSet())
Params(xs) = Params(Buffer(xs, false), IdSet{Any}(xs))
Params(ps::Params) = ps
Params(xs::Tuple) = Params(collect(xs))

@forward Params.order Base.iterate, Base.length, Base.getindex

Base.in(x, ps::Params) = x in ps.params

Base.map(::typeof(_project), args::Tuple{Params}, grad) = grad  # skip _project in gradient(f, ::Params)

function Base.union!(ps::Params, itrs...)
  foreach(itr -> foreach(x -> push!(ps, x), itr), itrs)
  return ps
end

Base.copy(ps::Params) = union!(Params(), ps)
Base.union(ps::Params, itrs...) = union!(copy(ps), itrs...)
Base.issetequal(ps1::Params, ps2::Params) = issetequal(ps1.params, ps2.params)
Base.issetequal(ps1::Params, x::Base.AbstractSet) = issetequal(ps1.params, x)
Base.issetequal(x::Base.AbstractSet, ps1::Params) = issetequal(x, ps1.params)

function Base.intersect!(ps::Params, itrs...)
  for itr in itrs
    for x in collect(ps)
      x ∉ itr && delete!(ps, x)
    end
  end
  return ps
end

Base.intersect(ps::Params, itrs...) = intersect!(copy(ps), itrs...)

function Base.push!(ps::Params, x)
  if !(x in ps.params)
    push!(ps.order, x)
    push!(ps.params, x)
  end
  return ps
end

Base.push!(ps::Params, x...) = (foreach(x -> push!(ps, x), x); ps)

function Base.delete!(ps::Params, x)
  if x in ps.params
    delete!(ps.params, x)
    i = findfirst(y -> y === x, ps.order)
    deleteat!(ps.order, i)
  end
  return ps
end

Base.Broadcast.broadcasted(f, ps::Params) = broadcasted(f, ps.order)

@adjoint function Broadcast.broadcasted(f::Function, ps::Params)
  f.(ps), _ -> throw(ArgumentError("Zygote.Params does not support broadcasting within gradients, try iteration `for p in ps`"))
end

Base.:(==)(x::Params, y::Params) = x.order.data == y.order.data

function Base.show(io::IO, ps::Params)
  print(io, "Params([")
  join(io, ps.order, ", ")
  print(io, "])")
end


"""
    copy!(ps::Params, x::AbstractVector)
    copy!(x::AbstractVector, ps::Params)

Copies the content of array `x` into the parameters `ps` or viceversa.
The length of `x` has to be equal to the sum of the lengths
of all parameters.
"""
function copy!(ps::Params, x::AbstractVector)
  @assert length(x) == sum(length(p) for p in ps)
  i = 0
  for p in ps
    p .= reshape(x[i+1:i+length(p)], size(p))
    i += length(p)
  end
  ps
end

function copy!(x::AbstractVector, ps::Params)
  @assert length(x) == sum(length(p) for p in ps)
  i = 0
  for p in ps
    x[i+1:i+length(p)] .= vec(p)
    i += length(p)
  end
  x
end

"""
    Grads(...)

Dictionary-like container returned when taking gradients with
respect to implicit parameters. For an array `W`, appearing 
within `Params([W, A, B...])`, the gradient is `g[W]`.
"""
struct Grads
  grads::IdDict{Any,Any}
  params::Params
end

Base.show(io::IO, ps::Grads) = print(io, "Grads(...)")

@forward Grads.grads  Base.setindex!
@forward Grads.params  Base.length

const ADictOrGrads = Union{AbstractDict, Grads}

# Dictionary interface.
# Don't use the IdDict directly since it may contain some spurious pairs.
Base.haskey(gs::Grads, x) = x ∈ gs.params 
Base.keys(gs::Grads) = gs.params
Base.values(gs::Grads) = (gs.grads[p] for p in gs.params)

function Base.iterate(gs::Grads, state...)
  res = iterate(gs.params, state...)
  isnothing(res) && return nothing
  p, next_state = res
  return gs[p], next_state
end

function Base.getindex(gs::Grads, x)
  isbits(x) && error("Only reference types can be differentiated with `Params`.")
  return gs.grads[x]
end

"""
    copy!(gs::Grads, x::AbstractVector)
    copy!(x::AbstractVector, gs::Grads)

Copies the content of array `x` into the gradient object `gs` or vice versa. The
length of `x` has to be equal to the sum of the lengths of all gradients.
"""
function copy!(gs::Grads, x::AbstractVector)
  i = 0
  for p in gs.params
    gs[p] .= reshape(x[i+1:i+length(p)], size(p))
    i += length(p)
  end
  gs
end

function copy!(x::AbstractVector,  gs::Grads)
  i = 0
  for p in gs.params
    x[i+1:i+length(p)] .= vec(gs[p])
    i += length(p)
  end
  x
end

function Base.merge!(gs_dst::Grads, gs_srcs::Grads...)
  for gs_src in gs_srcs
    union!(gs_dst.params, gs_src.params)
    merge!(gs_dst.grads, gs_src.grads)
  end
  gs_dst
end

function Base.copy(gs::Grads)
  gs_new = Grads(IdDict(), gs.params)
  merge!(gs_new, gs)
end

broadcasted(f, gs::Grads, gss::ADictOrGrads...) = map(f, gs, gss...)

broadcasted(f, a::Numeric, gs::Grads) = map(x -> f(a, x), gs)
broadcasted(f, gs::Grads, a::Numeric) = map(x -> f(x, a), gs)

function materialize!(gs1::Grads, gs2::Grads)
  issetequal(gs1.params, gs2.params) || 
    throw(ArgumentError("Expected Grads objects with the same Params."))
  for p in gs1.params
    gs1[p] = gs2[p]
  end
  return gs1
end


function Base.map(f, gs1::Grads, gss::ADictOrGrads...)
  gsout = Grads(IdDict{Any,Any}(), Params(gs1.params))
  return map!(f, gsout, gs1, gss...)
end

function Base.map!(f, gsout::Grads, gss::ADictOrGrads...)
  all(issetequal(gsout.params, keys(gs)) for gs in gss) || 
    throw(ArgumentError("map! expects Grads objects with the same Params."))
  for p in gsout.params
    gsout[p] = f((_getformap(gs, p) for gs in gss)...) 
  end
  return gsout
end

function _getformap(gs, p)
  g = gs[p]
  isnothing(g) ? fill!(similar(p), 0) : g 
end

function pullback(f, ps::Params)
  cx = Context()
  y, back = _pullback(cx, f)
  y, function (Δ)
    for p in ps
      cache(cx)[p] = nothing
    end
    back(Δ)
    Grads(cx.cache, ps) # TODO make a copy
  end
end

# Code Reflection

function code_ir(f, T)
  m = meta(Tuple{Typeof(f),T.parameters...})
  return IR(m)
end

function code_irm(ex)
  isexpr(ex, :call) || error("@code_ir f(args...)")
  f, args = ex.args[1], ex.args[2:end]
  :(code_ir($(esc(f)), typesof($(esc.(args)...))))
end

macro code_ir(ex)
  code_irm(ex)
end

macro code_adjoint(ex)
  :(Adjoint($(code_irm(ex)), varargs = varargs($(esc(:($InteractiveUtils.@which $ex))), length(($(esc.(ex.args)...),)))))
end
