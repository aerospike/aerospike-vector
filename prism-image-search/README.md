# Prism image search
This demo application provides semantic search for a set of images
by indexing them using the [CLIP](https://huggingface.co/sentence-transformers/clip-ViT-B-32-multilingual-v1)
model created by OpenAI. This model generates vectors with semantic meaning 
from each image and stores it as a vector embedding in Aerospike. When a user
performs a query a vector embedding for the provided text is generated and
Proximus performs Approximate Nearest Neighbor(ANN) search to find relevant results .

## Install using docker compose

The easiest way to get the demo app up and running is by using docker compose.

To run using docker compose:

### 1. Docker login to Aerospike's jfrog artifactory
   Your username is your email and your password is your generate jfrog identity token.

```
docker login aerospike.jfrog.io 
```

### 2. Build the prism image 
```
cd prism-image-search && \\
docker build -t prism . -f Dockerfile-prism
```

### 3. Add an image dataset
To make the experience personal, you can use your own photos on your computer, or to index
a larger dataset you can browse image datasets on [Kaggle](https://www.kaggle.com/datasets).  

[This subset](https://www.kaggle.com/datasets/ifigotin/imagenetmini-1000) of the Imagenet
dataset is a good reasonable sized one (~4000 images) if you remove the `train` folder. 

Add the images you would like indexed to `container-volumes/prism/images` folder locally. 
New images added to this folder are indexed periodically. 

### 4. Start the environment
```
docker compose up
```

### 5. Perform an image search
Navigate to http://127.0.0.1:8080 and perform a search for words to find similar
images in your dataset. 

## Developing
This demo is build using [Python Flask](https://flask.palletsprojects.com/en/2.3.x/)
and [Vue.js](https://vuejs.org/). In order to developer follow the steps to 
setup your Python environment.

### Setup pip
Setup pip to use Aerospike PyPI repository following instructions [here](https://github.com/citrusleaf/aerospike-proximus-client-python/tree/main#using-the-client-from-your-application-using-pip).

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
python3 -m pip install -r requirements.txt --extra-index-url https://aerospike.jfrog.io/artifactory/api/pypi/aerospike-pypi-dev/simple 
```

### Configuration

The application can be configured by setting the following environment variable.
If not set defaults are used.

| Environment Variable        | Default            | Description                                                     |
|-----------------------------|--------------------|-----------------------------------------------------------------|
| APP_USERNAME                |                    | If set, the username for basic authentication                   |
| APP_PASSWORD                |                    | If set, the password for basic authentication                   |
| APP_INDEXER_PARALLELISM     | 1                  | To speed up indexing of quotes set this equal to or less than the number of CPU cores               |
| PROXIMUS_HOST               | localhost          | Proximus server seed host                                       |
| PROXIMUS_PORT               | 5000               | Proximus server seed host port                                  |
| PROXIMUS_ADVERTISED_LISTENER|                    | An optional advertised listener to use if configured on the proximus server                              |
| PROXIMUS_NAMESPACE          | test               | The aerospike namespace for storing the image records and index |
| PROXIMUS_INDEX_NAME         | prism-image-search | The name of the  index                                          |
| PROXIMUS_MAX_RESULTS        | 20                 | Maximum number of vector search results to return               |

### Setup networking (optional)

#### Run a proxy server like Nginx

Setup nginx to handle TLS as
shown [here](https://dev.to/thetrebelcc/how-to-run-a-flask-app-over-https-using-waitress-and-nginx-2020-235c).

#### Start the application

```shell
 waitress-serve --host 127.0.0.1 --port 8080 --threads 32 prism:app
```


#### Run for development

This mode is not recommended for demo on hosting for use. The server is known to
hang after being
idle for some time. This mode will reflect changes to the code without server
restart and hence is ideal for development.

```shell
FLASK_ENV=development FLASK_DEBUG=1 python3 -m flask --app prism  run --port 8080
```