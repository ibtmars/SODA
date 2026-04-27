# Experimental Data and Deployment Scripts for SDOA

This repository provides the experimental datasets and deployment scripts used in the evaluation of the SDOA oracle system. The data are organized by research question and support the empirical results reported in the manuscript.

## Research Questions

- RQ1: Functional validation of heterogeneous blockchain access through Oracle Adapters.
  - The corresponding workflow is described and illustrated in the manuscript; no separate raw-data directory is provided for this qualitative validation.

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

## Experimental Scope

The experiments were conducted in a Docker Compose-based single-host environment using EVM-compatible blockchain simulators, Kafka message forwarding, and Grafana k6 workload generation. The reported results should be interpreted as reproducible experimental evidence under the evaluated settings, rather than production throughput guarantees.