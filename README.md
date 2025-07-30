### TrimReport.jl

This is a proof-of-concept package to demonstrate annotated (typed) user code via JuliaLowering.jl + type-inference.

Take user code like:
```julia
function foo(v::Vector{Float64}, init::Union{Nothing,Float64})
   if init === nothing
       init = 0
   end

   result = init
   for elem in v
       result += elem
   end

   if result != (sum(v) + init)
       error("Unexpected result!")
   end

   return result
end
```

And add **type-on-hover** and **dispatch-on-hover** info:

<img width="526" height="327" alt="image (15)" src="https://github.com/user-attachments/assets/d29b6f73-01d7-49ae-98ec-9d35ddc87ca2" />

The output HTML is entirely standalone, and can be shared by sending to other users or publishing to the web.

#### Future plans

The eventual goal is to be able to include this in `--trim`, so that any errors can be contextualized with local inference information in your source code.

Before we can do that, we need to bring up JuliaLowering.jl on Base. Furthermore, the TrimVerifier runs on optimized IR, so our `debuginfo` needs to be improved to maintain provenance through the optimizer pipeline.
