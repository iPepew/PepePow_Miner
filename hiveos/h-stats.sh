#!/usr/bin/env bash

# The native miner does not expose a stable local statistics API yet. HiveOS
# requires both variables on every callback, so return a valid zero snapshot
# instead of null until the API is implemented.
khs=0
stats='{"hs":[],"hs_units":"khs","ar":[0,0,0],"uptime":0,"ver":"0.1.4","algo":"pepepow"}'
