import os


def get_bool_env(name, default):
    env = os.environ.get(name)

    if env is None:
        return default

    env = env.lower()

    if os.environ.get(name) in ["true", "1"]:
        return True
    else:
        return False


class Config(object):
    BASIC_AUTH_USERNAME = os.environ.get("APP_USERNAME") or ""
    BASIC_AUTH_PASSWORD = os.environ.get("APP_PASSWORD") or ""
    NUM_QUOTES = int(os.environ.get("APP_NUM_QUOTES") or 5000)
    AVS_HOST = os.environ.get("AVS_HOST") or "localhost"
    AVS_PORT = int(os.environ.get("AVS_PORT") or 5000)
    AVS_ADVERTISED_LISTENER = os.environ.get("AVS_ADVERTISED_LISTENER") or None
    AVS_INDEX_NAME = os.environ.get("AVS_INDEX_NAME") or "quote-semantic-search"
    AVS_NAMESPACE = os.environ.get("AVS_NAMESPACE") or "test"
    AVS_SET = os.environ.get("AVS_SET") or "quote-data"
    AVS_VERIFY_TLS = get_bool_env("VERIFY_TLS", True)
    AVS_MAX_RESULTS = int(os.environ.get("AVS_MAX_RESULTS") or 5)
    INDEXER_PARALLELISM = int(os.environ.get("APP_INDEXER_PARALLELISM") or 1)
    MAX_CONTENT_LENGTH = int(os.environ.get("MAX_CONTENT_LENGTH") or 10485760)
    AVS_IS_LOADBALANCER = get_bool_env("AVS_IS_LOADBALANCER", False)
    DATASET_FILE_PATH = (
        os.environ.get("DATASET_FILE_PATH")
        or "../container-volumes/quote-search/data/quotes.csv"
    )

    if NUM_QUOTES > 100000:
        NUM_QUOTES = 100000
