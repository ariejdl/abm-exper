module Utils

export visual_check

using Agents, Random
using Plots, GraphRecipes
using Graphs  # Added this to provide nv()

function visual_check(model, tiers)
    g = model.space.graph
    # nv (number of vertices) is now available from Graphs
    N_NODES = nv(g) 
    
    println("Graph nodes: $N_NODES")
    println("Total agents: $(nagents(model))")

    xs = zeros(N_NODES)
    ys = zeros(N_NODES)

    WIDTH = 8.0
    TIER_HEIGHT = 2.0
    Y_MARGIN = 0.5

    names = Vector{String}(undef, N_NODES)

    # Consumer node (vertex 1)
    xs[1] = WIDTH / 2
    ys[1] = 0.0

    names[1] = "Consumers"

    for (tier, firm_ids) in model.firms_by_tier
        n = length(firm_ids)
        for (i, fid) in enumerate(firm_ids)
            f = model[fid]
            xs[f.pos] = (i / (n + 1)) * WIDTH
            ys[f.pos] = Float64(tier) * TIER_HEIGHT

            names[f.pos] = "$fid"
        end
    end

    p = graphplot(g,
        x=xs,
        y=ys,
        arrow=(:closed, :head, 0.01),
        curves=false,
        nodeshape=:circle,
        nodesize=0.3,
        nodestrokecolor=:grey,
        nodestrokewidth=2,
        names=names,
        size=(800, 600),
        xlims=(0.0, WIDTH),
        ylims=(-Y_MARGIN, tiers * TIER_HEIGHT + Y_MARGIN) # Pass tiers as an argument
    )
    display(p)
    readline()
end

end # module