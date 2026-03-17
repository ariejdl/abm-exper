
import pandas as pd
import matplotlib.pyplot as plt

df = pd.read_csv('run.csv')

'''
consumer_df = df[df['agent_type'] == 'Consumer']
consumer_df = consumer_df.groupby('time').sum(numeric_only=True).reset_index()[
   ['time', 'pending_orders', 'firm_orders', 'qty_received']
]
'''
filtered_df = df[df['id'] == 1003]

for col in ['pending_orders', 'qty_received']:
  #consumer_df[col] = consumer_df[col].cumsum()
  continue

print(df)

tier1_ids = range(1021, 1031)
tier2_ids = range(1031, 1041)
tier3_ids = range(1041, 1051)

tiers = reversed([tier1_ids, tier2_ids, tier3_ids])

def consumer_plot(df):
  plt.plot(df['time'], df['pending_orders'], label='Pending Orders')
  plt.plot(df['time'], df['qty_received'], label='Quantity Received')

  plt.xlabel('Time')
  plt.ylabel('Quantity')
  plt.title('Pending Orders and Quantity Received over Time')
  plt.legend()
  plt.grid(True)
  plt.savefig('figs/_orders_vs_received.png')

def firm_plot(main_df):

  fig, axs = plt.subplots(3, 10, figsize=(35, 10))

  have_legend = False

  for ids, row in zip(tiers, axs):
    for id, ax in zip(ids, row):

      df = main_df[main_df['id'] == id]

      ax.plot(df['time'], df['pending_orders'], label='Pending')
      ax.plot(df['time'], df['inventory'], label='Inventory')
      ax.plot(df['time'], df['firm_orders'], label='Order Count')
      ax.plot(df['time'], df['qty_ordered'], label='Quantity Ordered')
      ax.plot(df['time'], df['pending_demand'], label='Pending Demand')
      ax.plot(df['time'], df['qty_manufactured'], label='Manufactured')
      ax.plot(df['time'], df['qty_received'], label='Received')

      ax.set_title('Firm {}'.format(id))
      if not have_legend:
        ax.legend()
        have_legend = True
      ax.grid(True)      

  plt.tight_layout()
  # plt.show()
  plt.savefig('figs/_firm_plot.png')

# consumer_plot(filtered_df)

firm_plot(df)