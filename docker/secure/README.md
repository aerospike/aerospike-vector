# Secure Aerospike Vector Search (AVS) Example

This directory contains configuration files to run Aerospike Vector Search (AVS) with TLS encryption and mutual TLS (mTLS) authentication between the AVS server and a client application (`search.py`).

## Purpose

This setup demonstrates how to:
1.  Generate a Certificate Authority (CA).
2.  Generate server certificates for AVS, signed by the CA.
3.  Generate client certificates for an example application (`search.py`), signed by the CA.
4.  Configure AVS via `docker-compose.yaml` to use TLS for network encryption and require client certificates for authentication (mTLS).
5.  Connect the `search.py` example to the secure AVS instance using the generated client certificates.

## Setup and Launch

1.  **Generate Certificates:**
    Navigate to this directory (`docker/secure`) in your terminal and run the certificate generation script:
    ```bash
    ./gen_ssh.sh
    ```
    This will create a `config/tls` subdirectory containing the necessary keys and certificates:
    *   `ca.crt`: The Certificate Authority certificate.
    *   `server.key`, `server.crt`: AVS server private key and certificate.
    *   `client.key`, `client.crt`: Client private key and certificate (for `search.py`).
    *   `truststore.jks`, `storepass`: Java truststore files (potentially used by AVS internally).

2.  **Start AVS Container:**
    From this directory (`docker/secure`), start the AVS container using Docker Compose:
    ```bash
    docker-compose up
    ```
    This will start the AVS server, configured according to `docker-compose.yaml` to use the generated TLS certificates and require client authentication. Check the container logs (`docker-compose logs -f avs`) to ensure it starts correctly.

## Connecting `search.py`

To connect the `basic-search/search.py` example application to this secure AVS instance, you need to provide the client certificates and the CA certificate using its command-line arguments.

Navigate to the `basic-search` directory (relative to the root of the `proximus-examples` repository) and run `search.py` like this:

```bash
python search.py \
    --host localhost \
    --port 5555 \
    --tls-cafile ../docker/secure/config/tls/ca.crt \
    --tls-certfile ../docker/secure/config/tls/client.crt \
    --tls-keyfile ../docker/secure/config/tls/client.key
```

**Explanation of Flags:**

*   `--host localhost`: The hostname where AVS is running (as exposed by Docker Compose).
*   `--port 5555`: The TLS port AVS is listening on (defined in `docker-compose.yaml`).
*   `--root-certificate ../docker/secure/config/tls/ca.crt`: Path to the CA certificate file. The client uses this to verify the server's certificate.
*   `--certificate-chain ../docker/secure/config/tls/client.crt`: Path to the client's certificate file. The client presents this to the server for authentication.
*   `--private-key ../docker/secure/config/tls/client.key`: Path to the client's private key file, corresponding to the client certificate.

This command tells `search.py` to establish a TLS connection with AVS, verify the server using `ca.crt`, and authenticate itself using `client.crt` and `client.key`. 