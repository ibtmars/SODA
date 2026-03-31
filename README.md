# Experimental Data for the SDOA Oracle System

This directory contains the experimental datasets used in the evaluation of the SDOA oracle system. The data is organized by research question and supports the empirical results reported in the paper.

## Research Questions

- RQ2: How do the costs per request vary across the four service modes in the SDOA architecture?
  - Data directory: `RQ2/exe1/`
- RQ3: Does SDOA scale well under heavy workloads and saturation?
  - Data directories: `RQ3/End-to-end execution latency/`, `RQ3/System throughput and P95 latency/`
- RQ4: How resilient is SDOA against system failures and malicious attacks?
  - Data directories: `RQ4/exe3/`, `RQ4/exp3_scenarios/`, `RQ4/exp3_timelines/`

## Directory Structure

- `RQ2/`: Experimental results for per-request cost analysis across different service modes.
- `RQ3/`: Experimental results for scalability, throughput, and latency under increasing workload pressure.
- `RQ4/`: Experimental results for resilience evaluation under failures and adversarial conditions.
- `deploy-scripts/`: Deployment and synchronization scripts used to run the experiments.
