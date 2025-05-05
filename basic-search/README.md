# Basic vector search example

A simple Python application that demonstrates vector ANN index creation, 
vector record insertion, and basic ANN query against the AVS server using the Python client.

## Prerequisites

1. A Python 3.10 - 3.11 environment and familiarity with the Python programming language (see [Setup Python Virtual Environment](../prism-image-search/README.md#set-up-python-virtual-environment)).
2. An Aerospike Vector Search host (sandbox or local) running AVS 0.11.1 or newer.

## Setup build Python Virtual Environment

This is the recommended mode for building the python client.

```shell
# Create virtual environment to isolate dependencies.
python3 -m venv .venv
source .venv/bin/activate
```

## Install dependencies

```shell
python3 -m pip install -r requirements.txt
```

## Configuration

The application can be configured by setting the following command line flags.
If not set defaults are used.

[!NOTE]
It is best practice to store AVS index and record data in separate namespaces.
By default, this application stores its AVS index in the "avs-index" namespace, and AVS records in "avs-data".
If your Aerospike database configuration does not define these namespaces you will see an error.
You may change the --namespace and --index-namespace to other values, like the default Aerospike "test" namespace, to use other namespaces.

| Command Line Flag  | Default     | Description                                                             |
|--------------------|-------------|-------------------------------------------------------------------------|
| --host             | localhost   | AVS host used for initial connection                                    |
| --port             | 5000        | AVS server seed host port                                               |
| --namespace        | avs-data    | The Aerospike namespace for storing the quote records                   |
| --set              | basic-data  | The Aerospike set for storing the quote records                         |
| --index-namespace  | avs-index   | The Aerospike namespace for storing the HNSW index                      |
| --index-set        | basic-index | The Aerospike set for storing the HNSW index                            |
| --no-load-balancer | False       | If true, cluster tending is enabled                                     |

## Security Configuration (TLS/Auth)

This example supports connecting to Aerospike Vector Search instances secured with TLS and authentication.

### Connecting to a Secure AVS Instance (mTLS)

To connect to an AVS instance requiring mutual TLS (mTLS), where both the server and client must present valid certificates signed by a trusted Certificate Authority (CA), use the following command-line arguments:

*   `--root-certificate <path/to/ca.crt>`: Path to the CA certificate file used to verify the AVS server certificate.
*   `--certificate-chain <path/to/client.crt>`: Path to the client certificate file presented to AVS for authentication.
*   `--private-key <path/to/client.key>`: Path to the client's private key file corresponding to the client certificate.

**Example using certificates from `docker/secure`:**

If you have generated certificates using the `docker/secure/gen_ssh.sh` script, you can connect from the `basic-search` directory like this:

```bash
python search.py \
    --host localhost \
    --port 5555 \
    --root-certificate ../docker/secure/config/tls/ca.crt \
    --certificate-chain ../docker/secure/config/tls/client.crt \
    --private-key ../docker/secure/config/tls/client.key
```
*(Note: Ensure the AVS server is running and configured for TLS on port 5555, as set up by `docker/secure/docker-compose.yaml`)*

### Connecting to a Secure AVS Instance (Server-Side TLS Only - e.g., Kubernetes)

If the AVS instance uses TLS for encryption but does not require client authentication (mTLS), you only need to provide the CA certificate to verify the server.

*   `--root-certificate <path/to/ca.crt>`: Path to the CA certificate file used to verify the AVS server certificate.

**Example using CA certificate from `kubernetes/generated`:**

If you have generated certificates using the scripts in the `kubernetes` directory (which creates a `generated` subdirectory), you can connect from the `basic-search` directory like this:

*(Note: The common name on the certificate and the host name of your K8s cluster may not match, you may use --tls-hostname-override to override the expected host name)

```bash
# Replace <k8s_avs_host> and <k8s_avs_tls_port> with your Kubernetes service details
python search.py \
    --host <k8s_avs_host> \
    --port <k8s_avs_tls_port> \
    --root-certificate ../kubernetes/generated/certs/ca.aerospike.com.pem \
    --tls-hostname-override <host_name> \
    --username <username> \
    --password <password>
```

### Basic Authentication

If the AVS instance uses basic username/password authentication (and **not** mTLS, as they are typically mutually exclusive for client identity), use these flags:

*   `--username <your_username>`
*   `--password <your_password>`

```bash
python search.py \
    --host <avs_host> \
    --port <avs_port> \
    --username <username> \
    --password <password>
```

## Run the search demo

Run with --help to see available the example's available configuration.
```shell
python3 search.py --help
```

Run the example.
```shell
python3 search.py --port 5555
```
