
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

print(df)

tier1_ids = range(1021, 1031)
tier2_ids = range(1031, 1041)
tier3_ids = range(1041, 1051)

tiers = reversed([tier1_ids, tier2_ids, tier3_ids])

def consumer_plot_grid(df, ids):
    fig, axes = plt.subplots(4, 5, figsize=(30, 15), sharex=True, sharey=True)
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

target_ids = df['id'].unique()[:20]
consumer_plot_grid(df, target_ids)

import matplotlib.pyplot as plt

def firm_plot(main_df, tiers):
    # sharex and sharey normalize the axes across the entire grid
    fig, axs = plt.subplots(3, 10, figsize=(60, 15), sharex=True, sharey=True)
    
    have_legend = False

    for ids, row in zip(tiers, axs):
        for id_val, ax in zip(ids, row):
            df = main_df[main_df['id'] == id_val]

            ax.plot(df['time'], df['pending_orders'], label='Pending')
            ax.plot(df['time'], df['inventory'], label='Inventory')
            ax.plot(df['time'], df['firm_orders'], label='Order Count')
            ax.plot(df['time'], df['qty_ordered'], label='Quantity Ordered')
            ax.plot(df['time'], df['pending_demand'], label='Pending Demand')
            ax.plot(df['time'], df['qty_manufactured'], label='Manufactured')
            ax.plot(df['time'], df['cancelled_orders'], label='Cancelled')
            ax.plot(df['time'], df['qty_received'], label='Received')

            ax.set_title(f'Firm {id_val}')
            if not have_legend:
                ax.legend(loc='upper right')
                have_legend = True
            ax.grid(True)

    # Adding global labels
    fig.supxlabel('Time', fontsize=16)
    fig.supylabel('Quantity / Units', fontsize=16)
    
    # Adjust layout to accommodate global labels
    plt.tight_layout()
    plt.savefig('figs/firm_plot.png')

firm_plot(df, tiers)