# Quote Semantic search
This demo application provides semantic search for an included [dataset of quotes](https://archive.org/details/quotes_20230625)
by indexing them using the [MiniLM](https://huggingface.co/sentence-transformers/all-MiniLM-L6-v2)
model created by OpenAI. This model was used to generate the vectors with semantic meaning in container-volumes/quote-search/data/quote-embeddings.csv.tgz
which are loaded by this app into Aerospike.
When a user performs a query a vector embedding for the provided text is generated and
Aerospike Vector Search (AVS) performs Approximate Nearest Neighbor(ANN) search to find relevant results.


## Prerequisites
You don't have to know Aerospike to get started, but you do need the following:

1. A Python 3.10 - 3.11 environment and familiarity with the Python programming language (see [Setup Python Virtual Environment](../prism-image-search/README.md#set-up-python-virtual-environment)).
2. An Aerospike Vector Search host (preview or local) running AVS 0.11.1 or newer.

## Configure AVS host

If you are connecting to a preview environment, you'll need to set the following:
```shell
export AVS_HOST=<PREVIEW_ENV_IP>
```

## Install Dependencies
Change directories into the `quote-search` folder.

```shell
cd quote-search
```

Install dependencies using requirements.text 
```shell 
python3 -m pip install -r requirements.txt
```
## Start the application

> [!IMPORTANT]
> If you did not use a virtualenv when installing dependencies `waitress-serve` will
> likely not be in your path. 

> [!IMPORTANT]
> If Aerospike Vector Search is not running on port 5555 change the command below to match your deployment.

```shell
AVS_PORT=5555 waitress-serve --host 127.0.0.1 --port 8080 --threads 32 quote_search:app
```

## Performing a quote search
<!-- markdown-link-check-disable-next-line -->
Navigate to http://127.0.0.1:8080/search and perform a search for quotes based on a description.


## Install using docker compose
If you have a license key, you can easily set up Aerospike, AVS, and the quote-semantic-search
app using docker-compose. 

### 1. Build the image 
```
docker build -t quote-search . -f Dockerfile-quote-search
```

### 2. Add features.conf
AVS needs an Aerospike features.conf file with the vector-search feature enabled.
Optionally set `FEATURE_KEY` environment variable with the location of your `features.conf` file.

If no variable is set it will expect the features.conf to be in  `container-volumes/avs/etc/aerospike-vector-search`



### 3. Start the environment
#### Using Aerospike 7.0
```
FEATURE_KEY=/path/to/features.conf docker compose -f docker-compose-dev.yml up

```
#### Using Aerospike 6.4
```
FEATURE_KEY=/path/to/features.conf docker compose -f docker-compose-asdb-6.4.yml up

```


## Developing
This demo is built using [Python Flask](https://flask.palletsprojects.com/en/2.3.x/)
and [Vue.js](https://vuejs.org/). In order to develop, follow the steps to 
set up your Python environment.

### Setup Python Virtual Environment

```shell
# Virtual environment to isolate dependencies.
# Use your Operating system specific installation method
sudo apt-get install python3-venv
python3 -m venv .venv
source .venv/bin/activate
```

### Install dependencies

```shell
cd quote-search
python3 -m pip install -r requirements.txt 
```

### Configuration

The application can be configured by setting the following environment variable.
If not set defaults are used.

[!NOTE]
It is best practice to store AVS index and record data in separate namespaces.
By default, this application stores its AVS index in the "avs-index" namespace, and AVS records in "avs-data".
If your Aerospike database configuration does not define these namespaces you will see an error.
You may change the AVS_NAMESPACE and AVS_INDEX_NAMESPACE to other values, like the default Aerospike "test" namespace, to use other namespaces.

[!NOTE]
Using a load balancer with AVS is best practice. Therefore, AVS_IS_LOADBALANCER defaults to True.
This works fine for AVS clusters with a load balancer or clusters with only 1 node. If you are using
the examples with an AVS cluster larger than 1 node without load balancing you should set AVS_IS_LOADBALANCER to False.

| Environment Variable      | Default               | Description                                                                                                                                              |
|---------------------------|-----------------------|----------------------------------------------------------------------------------------------------------------------------------------------------------|
| APP_USERNAME              |                       | If set, the username for basic authentication for the app UI                                                                                             |
| APP_PASSWORD              |                       | If set, the password for basic authentication for the app UI                                                                                             |
| APP_NUM_QUOTES            | 5000                  | The number of quotes to index. If time and space allows the max is 100000. **Hint:** To keep the app from re-indexing quotes on subsequent runs set to 0 |
| APP_INDEXER_PARALLELISM   | 1                     | To speed up indexing of quotes set this equal to or less than the number of CPU cores                                                                    |
| AVS_HOST                  | localhost             | AVS server seed host                                                                                                                                     |
| AVS_PORT                  | 5000                  | AVS server seed host port                                                                                                                                |
| AVS_ADVERTISED_LISTENER   |                       | An optional advertised listener to use if configured on the AVS server                                                                                   |
| AVS_NAMESPACE             | avs-data              | The Aerospike namespace for storing the quote records                                                                                                    |
| AVS_SET                   | quote-data            | The Aerospike set for storing the quote records                                                                                                          |
| AVS_INDEX_NAMESPACE       | avs-index             | The Aerospike namespace for storing the HNSW index                                                                                                       |
| AVS_INDEX_SET             | quote-index           | The Aerospike set for storing the HNSW index                                                                                                             |
| AVS_INDEX_NAME            | quote-semantic-search | The name of the  index                                                                                                                                   |
| AVS_MAX_RESULTS           | 5                     | Maximum number of vector search results to return                                                                                                        |
| AVS_IS_LOADBALANCER       | True                  | If true, the first seed address will be treated as a load balancer node                                                                                  |
| AVS_AUTH_USERNAME         | None                  | Username for AVS basic authentication                                                                                                                    |
| AVS_AUTH_PASSWORD         | None                  | Password for AVS basic authentication                                                                                                                    |
| AVS_TLS_CA_FILE           | None                  | Path to the PEM encoded root CA certificate file (for TLS)                                                                                               |
| AVS_TLS_CERT_FILE         | None                  | Path to the PEM encoded certificate chain file (for mTLS client auth)                                                                                    |
| AVS_TLS_KEY_FILE          | None                  | Path to the PEM encoded private key file (for mTLS client auth)                                                                                          |
| AVS_TLS_NAME_OVERRIDE     | None                  | Override hostname for SSL certificate validation (for TLS)                                                                                               |
| AVS_VERIFY_TLS            | True                  | Set to false to disable TLS certificate verification (use with caution)                                                                                  |
| DATASET_FILE_PATH         | ../container-volumes/quote-search/data/quote-embeddings.csv | Path to the quote embeddings dataset file                                                                          |

### Setup networking (optional)

#### Run a proxy server like Nginx

Setup nginx to handle TLS as
shown [here](https://dev.to/thetrebelcc/how-to-run-a-flask-app-over-https-using-waitress-and-nginx-2020-235c).

#### Start the application

```shell
AVS_PORT=5555 waitress-serve --host 127.0.0.1 --port 8080 --threads 32 quote_search:app
```

#### Run for development

This mode is not recommended for demo on hosting for use. The server is known to
hang after being
idle for some time. This mode will reflect changes to the code without server
restart and hence is ideal for development.

```shell
FLASK_ENV=development FLASK_DEBUG=1 python3 -m flask --app quote_search  run --port 8080
```

### Generating the embeddings
The quote search example application loads pre-computed quote embeddings from container-volumes/quote-search/data/quote-embeddings.csv.tgz.
This file can be re-generated using the pre-embed.py script in the scripts folder.

## Security Configuration (TLS/Auth)

This application supports connecting to Aerospike Vector Search instances secured with TLS and authentication via environment variables.

### Connecting to a Secure AVS Instance (mTLS)

To connect to an AVS instance requiring mutual TLS (mTLS), where both the server and client must present valid certificates signed by a trusted Certificate Authority (CA), set the following environment variables before running the application:

*   `AVS_TLS_CA_FILE=<path/to/ca.crt>`: Path to the CA certificate file used to verify the AVS server certificate.
*   `AVS_TLS_CERT_FILE=<path/to/client.crt>`: Path to the client certificate file presented to AVS for authentication.
*   `AVS_TLS_KEY_FILE=<path/to/client.key>`: Path to the client's private key file corresponding to the client certificate.
*   `AVS_HOST=<avs_hostname>`: (e.g., `localhost`)
*   `AVS_PORT=<avs_tls_port>`: (e.g., `5555`)

**Example using certificates from `docker/secure`:**

If you have generated certificates using the `docker/secure/gen_ssh.sh` script and are running the secure AVS via `docker/secure/docker-compose.yaml`, you can configure the Quote Search application like this:

```bash
export AVS_HOST=localhost
export AVS_PORT=5555
export AVS_TLS_CA_FILE=../docker/secure/config/tls/ca.crt
export AVS_TLS_CERT_FILE=../docker/secure/config/tls/client.crt
export AVS_TLS_KEY_FILE=../docker/secure/config/tls/client.key

# Then run the application
```
*(Note: Ensure the AVS server is running and configured for TLS on port 5555)*

### Connecting to a Secure AVS Instance (Server-Side TLS Only - e.g., Kubernetes)

If the AVS instance uses TLS for encryption but does not require client authentication (mTLS), you only need to provide the CA certificate to verify the server. Set the following environment variables:

*   `AVS_TLS_CA_FILE=<path/to/ca.crt>`: Path to the CA certificate file used to verify the AVS server certificate.
*   `AVS_HOST=<avs_hostname>`
*   `AVS_PORT=<avs_tls_port>`

**Example using CA certificate from `kubernetes/generated`:**

If you have generated certificates using the scripts in the `kubernetes` directory (which creates a `generated` subdirectory), you can configure the Quote Search application like this:

*(Note: The common name on the certificate and the host name of your K8s cluster may not match, you may use AVS_TLS_NAME_OVERRIDE to override the expected host name)

```bash
# Replace <k8s_avs_host> and <k8s_avs_tls_port> with your Kubernetes service details
export AVS_HOST=<k8s_avs_host>
export AVS_PORT=<k8s_avs_tls_port>
export AVS_TLS_CA_FILE=../kubernetes/generated/certs/ca.aerospike.com.pem
export AVS_TLS_NAME_OVERRIDE=<host_name>
export AVS_AUTH_USERNAME=<username>
export AVS_AUTH_PASSWORD=<password>


# Then run the application
```

### Basic Authentication

If the AVS instance uses basic username/password authentication (and **not** mTLS, as they are typically mutually exclusive for client identity), set these environment variables:

*   `AVS_AUTH_USERNAME=<your_username>`
*   `AVS_AUTH_PASSWORD=<your_password>`

```bash
export AVS_HOST=<avs_host>
export AVS_PORT=<avs_port>
export AVS_AUTH_USERNAME=<username>
export AVS_AUTH_PASSWORD=<password>

# Then run the application
```