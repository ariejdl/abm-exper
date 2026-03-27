
import math
import json
import pandas as pd
import matplotlib.pyplot as plt


df = pd.read_csv('run.csv')

# if were to use cum sum, might be correct to check deltas on some columns first
'''
consumer_df = df[df['agent_type'] == 'Consumer']
consumer_df = consumer_df.groupby('time').sum(numeric_only=True).reset_index()[
   ['time', 'pending_orders', 'firm_orders', 'qty_received']
]
'''

for col in ['pending_orders', 'qty_received']:
  #consumer_df[col] = consumer_df[col].cumsum()
  continue

metadata = json.loads(open('run_metadata.json').read())

sorted_tier_keys = sorted(metadata['firms'].keys(), reverse=True)
tiers = [metadata['firms'][key] for key in sorted_tier_keys]

def plot_size(ids):
    n = len(ids)
    # Calculate rows (floor of sqrt) and columns (floor + 1)
    nrows = math.floor(math.sqrt(n))
    ncols = nrows + 1
    
    # Safety check to ensure all IDs fit in the grid
    while nrows * ncols < n:
        if ncols <= nrows:
            ncols += 1
        else:
            nrows += 1

    return nrows, ncols

def consumer_plot_grid(df, ids):
    nrows, ncols = plot_size(ids)
    fig, axes = plt.subplots(nrows, ncols, figsize=(30, 15), sharex=True, sharey=True)
    axes = axes.flatten()  # Collapse 4x20 array into 1D for easy iteration

    for i, id_val in enumerate(ids):
        ax = axes[i]
        subset = df[df['id'] == id_val]
        
        ax.plot(subset['time'], subset['pending_orders'], label='Pending')
        ax.plot(subset['time'], subset['cancelled_orders'], label='Cancelled')
        ax.plot(subset['time'], subset['qty_received'], label='Received')
        
        ax.set_title(f'Consumer {id_val}')
        ax.grid(True)
        if i == 0:  # Add legend to the first plot to avoid clutter
            ax.legend()

    fig.text(0.5, 0.04, 'Time', ha='center')
    fig.text(0.04, 0.5, 'Quantity', va='center', rotation='vertical')
    plt.tight_layout(rect=[0.05, 0.05, 1, 0.95])
    plt.savefig('figs/consumers_grid.png')

consumer_ids = list(df[df['agent_type'] == 'Consumer']['id'].unique())
consumer_plot_grid(df, consumer_ids)

def bullwhip_calc(tier, tier_df):
    # Group by time to sum all firms' activity per tick
    tier_totals = tier_df.groupby('time').agg({
        'pending_demand': 'sum',
        'qty_order_received': 'sum'
    })

    # Calculate Tier Variance on differenced series
    var_tier_out = tier_totals['pending_demand'].var()
    var_tier_in = tier_totals['qty_order_received'].var()

    # Total Tier Bullwhip Ratio
    bwr_total_tier = var_tier_out / var_tier_in
    print(f"Total for Tier {tier} Bullwhip Ratio: {bwr_total_tier}")

def firm_plot(main_df, tiers):
    # Add extra column for totals
    n_rows = len(tiers)
    n_cols = len(tiers[0]) + 1  # +1 for totals column

    # sharex and sharey normalize the axes across the entire grid
    fig, axs = plt.subplots(n_rows, n_cols,
                            figsize=(60 + 15, 15), sharex=True, sharey=True)
    have_legend = False

    print("Should see consistent increasing of bullwhip value (variance orders out/in) by tier")

    for i, (ids, row) in enumerate(zip(tiers, axs)):
        tier_df = main_df[main_df['id'].isin(ids)]
        tier_df[['id', 'time', 'pending_demand', 'qty_order_received']]
        bullwhip_calc(len(tiers) - i, tier_df)

        # All columns except the last (totals) column
        firm_axes = row[:-1]
        totals_ax = row[-1]

        for id_val, ax in zip(ids, firm_axes):
            df = main_df[main_df['id'] == id_val]
            ax.plot(df['time'], df['pending_orders'], label='Pending')
            ax.plot(df['time'], df['inventory'], label='Inventory')
            ax.plot(df['time'], df['qty_order_received'], label='Quantity Order Received')
            ax.plot(df['time'], df['pending_demand'], label='Pending Demand')
            # ax.plot(df['time'], df['qty_manufactured'], label='Manufactured')
            ax.plot(df['time'], df['cancelled_orders'], label='Cancelled')
            ax.plot(df['time'], df['qty_received'], label='Received')
            ax.set_title(f'Firm {id_val}')
            if not have_legend:
                ax.legend(loc='upper right')
                have_legend = True
            ax.grid(True)

        # --- Totals column: sum all firms in this tier ---
        time_vals = tier_df['time'].unique()
        time_vals.sort()

        cols_to_total = [
            ('pending_orders',       'Pending'),
            ('inventory',            'Inventory'),
            ('qty_order_received',   'Quantity Order Received'),
            ('pending_demand',       'Pending Demand'),
            ('cancelled_orders',     'Cancelled'),
            ('qty_received',         'Received'),
        ]

        for col, label in cols_to_total:
            totals = tier_df.groupby('time')[col].sum().reindex(time_vals)
            totals_ax.plot(time_vals, totals, label=label)

        totals_ax.set_title(f'Tier {len(tiers) - i} Totals')
        totals_ax.grid(True)

    # Adding global labels
    fig.supxlabel('Time', fontsize=16)
    fig.supylabel('Quantity / Units', fontsize=16)

    plt.tight_layout()
    plt.savefig('figs/firm_plot.png')

firm_plot(df, tiers)