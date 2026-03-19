
include("utils.jl")

using CSV
using DataFrames
using JSON3

using Agents, Random
using Agents.DataFrames, Agents.Graphs
using StatsBase: sample, Weights
using .Utils: visual_check

N_CONSUMERS = 10
TIERS = 4
FIRMS_PER_TIER = 15
MIN_INVENTORY = 4
NUM_TICKS = 200
FIRM_DEMAND_MULTIPLIER = 2.0
CONSUMER_DEMAND_MULTIPLIER = 4.0

agent_id_counter = Ref(1_000)
custom_id_gen = () -> (agent_id_counter[] += 1; agent_id_counter[])

message_id_counter = Ref(100)
message_id_gen = () -> (message_id_counter[] += 1; message_id_counter[])

test_is_spike = (current_tick) -> (current_tick >= 20) && (current_tick <= 25)

#= TODO:
   - unit test, main idea: check that consumer and firm orders
     are succesfully and accurately fulfilled
=#

struct Message
    id::Int
    kind::Symbol
    quantity::Int
    sent_tick::Int
    original_id::Int
end

@agent struct Firm(GraphAgent)
    tier::Int
    inventory::Int
    inbox::Vector{Message}
    historical_demand::Vector{Int}
    pending_orders::Vector{Message}
    cancelled_orders::Vector{Message}
    fulfilled_orders::Set{Int}
end

@agent struct Consumer(GraphAgent)
    preference::Float32
    inbox::Vector{Message}
    pending_orders::Vector{Message}
    cancelled_orders::Vector{Message}
    fulfilled_orders::Set{Int}
end

# AI help
function forecast_demand(agent::Firm)
    # 1. Calculate raw current demand from messages
    orders = filter(msg -> msg.kind == :new_order, agent.inbox)
    raw_demand = length(orders) > 0 ? sum(msg -> msg.quantity, orders) : 0

    # 2. Smooth the demand forecast (Moving Average or Exponential Smoothing)
    # This represents what the agent expects the market to demand next period
    forecast = Float64(raw_demand)
    if length(agent.historical_demand) > 0
        forecast = 0.8 * raw_demand + 0.2 * agent.historical_demand[end]
    end

    # 3. Determine Production/Order Requirement
    # Target = Forecast + Safety Buffer - (Current Stock + Incoming Stock)
    target_production = forecast + MIN_INVENTORY - (agent.inventory + pendingDemand(agent))
    
    return Int(round(max(0, target_production)))
end

function cancel_upstream_orders(agent::Union{Consumer, Firm}, quantity_to_cancel::Int, model)
    current_tick = abmtime(model)

    # send order cancellation messages upstream if can find suitably sized
    # pending orders
    if quantity_to_cancel > 0
        suppliers = find_upstream_suppliers(agent, model)

        awaiting_orders = Vector{Tuple{Firm, Message}}()

        my_pending_order_ids = map(order -> order.id, agent.pending_orders)

        # check all suppliers for unfulfilled orders belonging to this agent
        for supplier in suppliers
            for message in supplier.inbox
                if (message.sent_tick <= current_tick - 1) &&
                    (message.kind == :new_order) &&
                    (message.id ∈ my_pending_order_ids)
                    push!(awaiting_orders, (supplier, message))
                end
            end
        end

        # take the biggest first
        sort!(awaiting_orders, by = (pair) -> pair[2].quantity, rev=true)

        current_cancel_quantity = 0

        # check if the orders to cancel are not too large
        for (supplier, order) in awaiting_orders
            new_cancel_quantity = current_cancel_quantity + order.quantity

            # how many orders can be cancelled?
            if new_cancel_quantity < quantity_to_cancel * 2.0

                current_cancel_quantity += order.quantity

                order_cancel_message = Message(
                    message_id_gen(), :order_cancellation, order.quantity, current_tick, order.id)

                push!(supplier.inbox, order_cancel_message)

                # clear supplier inbox
                deleteat!(supplier.inbox, findfirst(o -> o.id == order.id, supplier.inbox))

                # change my orders
                deleteat!(agent.pending_orders, findfirst(o -> o.id == order.id, agent.pending_orders))
                push!(agent.cancelled_orders, order)
            end
        end

        len_cancelled = length(awaiting_orders)        
        println("quantity cancelled: $quantity_to_cancel; order count: $len_cancelled")
    end    
end

function process_order_cancellations!(agent::Firm, model)
    current_tick = abmtime(model)

    processed_letters = Message[]
    total_quantity = 0

    # tot up cancelled orders
    for letter in agent.inbox
        # only process the order if it was sent at least one tick ago to prevent cascades
        if (letter.sent_tick <= current_tick - 1) && (letter.kind == :order_cancellation)
            total_quantity += letter.quantity
            push!(processed_letters, letter)
        end
    end

    cancel_upstream_orders(agent, total_quantity, model)

    filter!(letter -> letter ∉ processed_letters, agent.inbox)

end

# Firm step
function agent_step!(agent::Firm, model)
    current_tick = abmtime(model)

    suppliers = shuffle(abmrng(model), collect(find_upstream_suppliers(agent, model)))
    is_root = suppliers == []

    # do this first to clear any cancelled orders before computing demand
    process_order_cancellations!(agent, model)

    new_demand = forecast_demand(agent)
    
    # behavioural trait
    if (length(agent.historical_demand) > 1) &&
        (new_demand > agent.historical_demand[end] * 2.0)
        new_demand = Int(round(new_demand * FIRM_DEMAND_MULTIPLIER))
    end

    push!(agent.historical_demand, new_demand)

    if new_demand > 0
        if is_root
            push!(agent.inbox,
                Message(message_id_gen(), :manufacture, new_demand, current_tick, -1))
        else
            new_order = Message(message_id_gen(), :new_order, new_demand, current_tick, -1)
            push!(agent.pending_orders, new_order)
            push!(suppliers[1].inbox, new_order)
        end
    end

    # manufacture and fufilled orders first in order to be able to have maximum inventory
    # for new orders
    sort_order = Dict(
        :manufacture => 1,
        :fulfilled_order => 2,
        :new_order => 3,
        :order_cancellation => 4 # should already be handled
    )
    # primary and secondary sort
    sort!(agent.inbox, by = x -> (sort_order[x.kind], x.sent_tick))

    processed_letters = Message[]

    for letter in agent.inbox

        # only process the order if it was sent at least one tick ago to prevent cascades
        if letter.sent_tick <= current_tick - 1
            if letter.kind == :new_order

                # check if the new order can be fulfilled with inventory
                # otherwise have to wait until inventory increases
                quantity = letter.quantity

                # key condition to check if an order is now able to be fulfilled
                if agent.inventory >= quantity
                    agent.inventory -= quantity
                    # inform the downstream receiver of their goods being provided
                    # i.e. this is a mapping of a new_order to a fulfilled_order
                    # the quantity cascades to the next tier, the id is lost

                    receiver = find_downstream_receiver(agent, letter.id, model)
                    if isnothing(receiver)
                        throw(ErrorException("Error: could not find downstream receiver for order id: $letter.id"))
                    end

                    # currently only place where message to fulfill order and map to old message
                    push!(receiver.inbox,
                        Message(message_id_gen(), :fulfilled_order, quantity, current_tick, letter.id))

                    push!(processed_letters, letter)
                end

            elseif letter.kind == :fulfilled_order
                # increase the inventory, just like manufacture
                agent.inventory += letter.quantity
                clear_order(agent, letter.original_id)
                push!(processed_letters, letter)
            elseif letter.kind == :manufacture
                # manufacturing takes 2 ticks
                if letter.sent_tick <= current_tick - 2
                    if !is_root
                        throw(ErrorException("Error: only root nodes can manufacture"))
                    end
                    agent.inventory += letter.quantity
                    push!(processed_letters, letter)
                end
            elseif letter.kind == :order_cancellation
                continue
            else
                throw(ErrorException("Error: unrecognised letter: $letter.kind"))
            end
        end
    end

    filter!(letter -> letter ∉ processed_letters, agent.inbox)
end

function agent_step!(agent::Consumer, model)
    current_tick = abmtime(model)

    # Define spike parameters
    is_spike = test_is_spike(current_tick)
    probability = is_spike ? 1.0 : 0.5 # Guarantee orders during spike
    multiplier = is_spike ? CONSUMER_DEMAND_MULTIPLIER : 1 # * effectively this is a coded behavioural element *

    # make a new order
    if rand(abmrng(model)) <= probability
        # send order to one supplier

        quantity = 1

        for _ in 1:quantity:multiplier
            supplier = find_upstream_supplier(agent, model)
            new_order = Message(message_id_gen(), :new_order, quantity, current_tick, -1)
            push!(agent.pending_orders, new_order)
            push!(supplier.inbox, new_order)
        end
    end

    processed_letters = Message[]

    for letter in agent.inbox

        # only process the order if it was sent at least one tick ago to prevent cascades
        if letter.sent_tick <= current_tick - 1
            if letter.kind == :fulfilled_order
                # increase the inventory, just like manufacture
                if letter.quantity != 1
                    throw(ErrorException("agent expected quantity one"))
                end
                push!(processed_letters, letter)
                clear_order(agent, letter.original_id)
            else
                throw(ErrorException("Error: unrecognised letter: $letter.kind"))
            end
        end
    end

    make_order_cancellations!(agent, model)

    filter!(letter -> letter ∉ processed_letters, agent.inbox)
end

function make_order_cancellations!(agent::Consumer, model)
    current_tick = abmtime(model)

    orders_per_tick = Dict{Int, Vector{Message}}()
    for order in agent.pending_orders

        # only process the order if it was sent at least one tick ago to prevent cascades
        if order.sent_tick <= current_tick - 2 # older messages
            get!(orders_per_tick, order.sent_tick, Message[])
            push!(orders_per_tick[order.sent_tick], order)
        end
    end

    for orders in values(orders_per_tick)
        if length(orders) > 1
            # firms cancel one outstanding old order every tick, when there is
            # more than one order placed at a given tick

            order_to_cancel = rand(abmrng(model), orders)
            cancel_upstream_orders(agent, order_to_cancel.quantity, model)

        end
    end
end

function find_supplier_from_waiting_order(agent::Union{Consumer, Firm}, order_id::Int, model)
    upstream = inneighbors(model.space.graph, agent.pos)
    for supplier_pos in upstream
        for supplier in agents_in_position(supplier_pos, model)
            if any(order -> order.id == order_id, supplier.inbox)
                return supplier
            end
        end
    end
    return nothing
end

function find_upstream_suppliers(agent::Union{Firm, Consumer}, model)
    upstream = inneighbors(model.space.graph, agent.pos)
    Channel() do channel
        for supplier_pos in upstream
             for supplier in agents_in_position(supplier_pos, model)
                put!(channel, supplier)
             end
        end
    end
end

function find_upstream_supplier(agent::Union{Firm, Consumer}, model)
    upstream = inneighbors(model.space.graph, agent.pos)
    # i.e. root node
    if length(upstream) == 0
        return nothing
    end
    supplier_pos = sample(abmrng(model), upstream)
    supplier, _ = iterate(agents_in_position(supplier_pos, model))
    return supplier
end

function find_downstream_receiver(agent::Firm, order_id::Int, model)
    downstream = outneighbors(model.space.graph, agent.pos)
    for receiver_pos in downstream
        for receiver in agents_in_position(receiver_pos, model)
            if any(order -> order.id == order_id, receiver.pending_orders)
                return receiver
            end
            if any(order -> order.id == order_id, receiver.cancelled_orders)
                return receiver
            end
        end
    end
    return nothing
end

function clear_order(agent::Union{Firm, Consumer}, order_id::Int)
    if order_id in agent.fulfilled_orders
        throw(ArgumentError("Order $order_id has already been fulfilled"))
    end
    # orders that come directly from inventory are not pending in the receiver
    if any(order -> order.id == order_id, agent.pending_orders)
        deleteat!(agent.pending_orders, findfirst(order -> order.id == order_id, agent.pending_orders))
    end
    push!(agent.fulfilled_orders, order_id)
end

function model_initiation(seed = 0)
    rng = Xoshiro(seed)
    space = GraphSpace(SimpleDiGraph(0))

    consumer_ids = Int[]
    firms_by_tier = Dict{Int, Vector{Int}}()

    properties = Dict{Symbol, Any}(
        :space => space,
        :consumer_ids => consumer_ids,
        :firms_by_tier => firms_by_tier
    )

    model = StandardABM(Union{Firm, Consumer},
        space;
        scheduler = Schedulers.Randomly(),
        agent_step! = agent_step!,
        model_step! = model_step!,
        properties = properties,
        rng = rng)

    add_vertex!(model)  # one vertex for all consumers
    for _ in 1:N_CONSUMERS

        c = Consumer(
            id = custom_id_gen(),
            pos = 1,
            preference=rand(rng),
            inbox=Message[],
            pending_orders=Message[],
            cancelled_orders=Message[],
            fulfilled_orders=Set{Int}())

        add_agent!(c, c.pos, model)
        push!(model.consumer_ids, c.id)
    end

    consumer_pos = model[model.consumer_ids[1]].pos

    for tier in 1:TIERS
        firm_ids = Int[]

        for _ in 1:FIRMS_PER_TIER
            add_vertex!(model)
            idx = nv(model)

            f = Firm(
                id=custom_id_gen(),
                pos=idx,
                tier=tier,
                inventory=0,
                inbox=Message[],
                historical_demand=Int[],
                pending_orders=Message[],
                cancelled_orders=Message[],
                fulfilled_orders=Set{Int}())

            add_agent!(f, f.pos, model)
            push!(firm_ids, f.id)
        end

        firms_by_tier[tier] = firm_ids

        if tier == 1
            for fid in firm_ids
                add_edge!(model, model[fid].pos, consumer_pos)
            end
        else
            prev_ids = firms_by_tier[tier - 1]
            for fid in firm_ids

                my_idx = findfirst(==(fid), firm_ids)

                mapped_ids = [
                    mod1(my_idx - 1, FIRMS_PER_TIER),
                    my_idx,
                    mod1(my_idx + 1, FIRMS_PER_TIER)
                ]


                for prev_idx in mapped_ids
                    prev_id = prev_ids[prev_idx]
                    add_edge!(model, model[fid].pos, model[prev_id].pos)
                end
            end
        end

    end

    # Save this metadata
    open("run_metadata.json", "w") do io
        JSON3.write(io, Dict(
            "firms" => firms_by_tier
        ))
    end

    return model
end

function model_step!(model)
    tick = abmtime(model)
    println("Tick: $tick")
end

model = model_initiation()

# visual_check(model, TIERS)

# ===== reporting functions =====

inventoryFn = (agent::Firm) -> agent.inventory

pendingOrders = (agent::Consumer) -> length(agent.pending_orders)

cancelledOrders = (agent::Union{Consumer, Firm}) -> length(agent.cancelled_orders)

firmOrders = (agent::Firm) -> count(msg.kind == :new_order for msg in agent.inbox)

firmQuantityOrder = (agent::Firm) -> 
    sum(msg.quantity for msg in agent.inbox if msg.kind == :new_order; init=0)

firmQuantityManufacture = (agent::Firm) -> 
    sum(msg.quantity for msg in agent.inbox if msg.kind == :manufacture; init=0)

quantityReceived = (agent::Union{Consumer, Firm}) -> 
    sum(msg.quantity for msg in agent.inbox if msg.kind == :fulfilled_order; init=0)

function pendingDemand(agent::Union{Consumer, Firm})
    return sum(msg -> msg.quantity, filter(msg -> msg.kind == :manufacture, agent.inbox), init=0) +
        sum(msg -> msg.quantity, agent.pending_orders, init=0)
end

# ========

agent_reporters = [
    (pendingOrders, :pending_orders),
    (cancelledOrders, :cancelled_orders),
    (inventoryFn, :inventory),
    (firmQuantityOrder, :qty_ordered),
    (firmQuantityManufacture, :qty_manufactured),
    (quantityReceived, :qty_received),
    (pendingDemand, :pending_demand)
]

adata_funcs = [first(pair) for pair in agent_reporters]
new_names = [last(pair) for pair in agent_reporters]

data, _ = run!(model, NUM_TICKS; adata = adata_funcs)

rename!(data, vcat([:time, :id, :agent_type], new_names))

CSV.write("run.csv", data)