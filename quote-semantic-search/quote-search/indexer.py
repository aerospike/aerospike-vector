import ast
import csv
import itertools
from multiprocessing import get_context
import numpy
import os
import sys
from threading import Thread
import time
import logging
from tqdm import tqdm
import tarfile

from config import Config
from data_encoder import MODEL_DIM
from avs_client import avs_client
from aerospike_vector_search import types

logger = logging.getLogger(__name__)
logger.setLevel(logging.INFO)


def wait_for_indexing(timeout=30):
    index = avs_client.index(
        name=Config.AVS_INDEX_NAME,
        namespace=Config.AVS_NAMESPACE
    )
    index_status = index.status()

    timeout = float(timeout)
    while index_status.readiness != types.IndexReadiness.READY:
        time.sleep(0.5)
        
        timeout -= 0.5
        if timeout <= 0:
            raise Exception("timed out waiting for indexing to complete, "
                            "maybe standalone indexing is not configured on this AVS cluster")

        index_status = index.status()


def read_csv(filename):
    if not os.path.exists(filename) and os.path.exists(filename + ".tgz"):
        # Untar the file
        with tarfile.open(filename + ".tgz", "r:gz") as tar:
            tar.extractall(path=os.path.dirname(filename))

    with open(filename, "r", encoding="utf-8") as f:
        reader = csv.reader(f)
        next(reader)  # Skip the header
        for row in reader:
            yield row


DATASET_FILE = Config.DATASET_FILE_PATH
dataset = itertools.islice(read_csv(DATASET_FILE), Config.NUM_QUOTES)
index_created = False


def create_index():
    global index_created

    try:
        for index in avs_client.index_list():
            if (
                index["id"]["namespace"] == Config.AVS_NAMESPACE
                and index["id"]["name"] == Config.AVS_INDEX_NAME
            ):
                return

        avs_client.index_create(
            namespace=Config.AVS_NAMESPACE,
            name=Config.AVS_INDEX_NAME,
            sets=Config.AVS_SET,
            vector_field="quote_embedding",
            dimensions=MODEL_DIM,
            vector_distance_metric=types.VectorDistanceMetric.COSINE,
            # Use a standalone index so that initial data
            # is indexes in a batch immediately after creation
            mode=types.IndexMode.STANDALONE,
            index_storage=types.IndexStorage(namespace=Config.AVS_INDEX_NAMESPACE, set_name=Config.AVS_INDEX_SET),
        )

        index_created = True
    except Exception as e:
        logger.critical("Failed to connect to avs client %s", str(e))
        sys.exit(1)


def either(c):
    return "[%s%s]" % (c.lower(), c.upper()) if c.isalpha() else c


def index_data():
    try:
        if Config.INDEXER_PARALLELISM <= 1:
            for quote in tqdm(
                enumerate(dataset), "Indexing quotes", total=Config.NUM_QUOTES
            ):
                index_quote(quote)
        else:
            with get_context("spawn").Pool(
                processes=Config.INDEXER_PARALLELISM
            ) as pool:
                for _ in tqdm(
                    pool.imap(index_quote, enumerate(dataset)),
                    "Indexing quotes",
                    total=Config.NUM_QUOTES,
                ):
                    pass

        # Create the standalone index after writing all initial data
        # so that it will index it all in a batch
        logger.info("Creating index")
        create_index()
        logger.info("Successfully created the index")

        # Wait for initial indexing to complete
        # This is mostly done so that clusters without standalone indexing
        # enabled do not silently fail to index the initial data forever
        logger.info("Waiting for indexing to complete")
        wait_for_indexing()
        logger.info("Indexing complete")

    except Exception as e:
        logger.warning("Error indexing:" + str(e))
        import traceback

        traceback.print_exc()


def index_quote(id_quote):
    id, quote = id_quote
    # The quotes from the dataset are in the format: [quote, author, category, embedding]
    # The embedding is a string representation of a numpy.ndarray of floats that was pre-computed
    # using the pre-embed.py script in the /scripts directory.
    quote, author, category, embedding = quote
    # The embedding is stored as a string in the CSV file, It is a bytes object that was wrapped in quotes by the CSV writer,
    # so the embedding format is as follows: "b'[0.1, 0.2, 0.3, ...]'". 
    # We need to convert this string to a bytes object and then convert the bytes object to a numpy array.
    # First we evaluate the string including the quotes as a Python literal, which will give us a bytes object.
    embedding = ast.literal_eval(embedding)
    # Then we convert the bytes object to a numpy array.
    # dtype=numpy.float32 is required to convert the bytes object with its original float32 element type.
    # The dtype depends on the model used to generate the embeddings, which is defined in the pre-embed.py script.
    embedding = numpy.frombuffer(embedding, dtype=numpy.float32)
    doc = {"quote_id": id}
    doc["quote"] = quote
    doc["author"] = author
    doc["tags"] = category.split(",")
    logger.debug(f"Creating text vector embedding {id}")
    doc["quote_embedding"] = embedding  # Numpy array is supported by aerospike

    # Insert record
    try:
        avs_client.upsert(
            namespace=Config.AVS_NAMESPACE,
            set_name=Config.AVS_SET,
            key=doc["quote_id"],
            record_data=doc,
        )
    except types.AVSServerError as e:
        logger.warning(
            f"Error inserting vector embedding into avs {id}: {str(e)} quote: {quote}"
        )
        # Retry again
        pass


def start():
    # Index data once
    thread = Thread(target=index_data)
    thread.start()


if __name__ == "__main__":
    start()
