import argparse
import time
import logging

import aerospike_vector_search
from aerospike_vector_search import Client, Index, types, AVSServerError


listener_name = None
index_name = "basic_index"


def wait_for_indexing(index: Index, timeout=30):
    index_status = index.status()
    timeout = float(timeout)
    while index_status.readiness != types.IndexReadiness.READY:
        time.sleep(0.5)
        
        timeout -= 0.5
        if timeout <= 0:
            raise Exception("timed out waiting for indexing to complete, "
                            "maybe standalone indexing is not configured on this AVS cluster")

        index_status = index.status()


arg_parser = argparse.ArgumentParser(description="Aerospike Vector Search Example")
arg_parser.add_argument(
    "--host",
    dest="host",
    required=False,
    default="localhost",
    help="Aerospike Vector Search host.",
)
arg_parser.add_argument(
    "--port",
    dest="port",
    required=False,
    default=5000,
    help="Aerospike Vector Search port.",
)
arg_parser.add_argument(
    "--namespace",
    dest="namespace",
    required=False,
    default="avs-data",
    help="Aerospike namespace for vector data.",
)
arg_parser.add_argument(
    "--set",
    dest="set",
    required=False,
    default="basic-data",
    help="Aerospike set for vector data.",
)
arg_parser.add_argument(
    "--index-namespace",
    dest="index_namespace",
    required=False,
    default="avs-index",
    help="Aerospike namespace the for vector index.",
)
arg_parser.add_argument(
    "--index-set",
    dest="index_set",
    required=False,
    default="basic-index",
    help="Aerospike set for the vector index.",
)
arg_parser.add_argument(
    "--load-balancer",
    dest="load_balancer",
    action="store_true",
    required=False,
    # using a load balancer with AVS is best practice so this is the default
    # you should set this to False if you are not using a load balancer with an AVS cluster of more than 1 node
    default=True,
    help="Use this if the host is a load balancer.",
)
arg_parser.add_argument(
    "--no-load-balancer",
    dest="no_load_balancer",
    action="store_true",
    required=False,
    # you should set this to True if you are not using a load balancer with an AVS cluster of more than 1 node
    default=False,
    help="Use this if the host is not a load balancer.",
)
# tls args
arg_parser.add_argument(
    "--tls-cafile",
    dest="tls_cafile",
    required=False,
    default=None,
    help="Path to the PEM encoded root CA certificate file.",
)
arg_parser.add_argument(
    "--tls-certfile",
    dest="tls_certfile",
    required=False,
    default=None,
    help="Path to the PEM encoded certificate chain file for mTLS.",
)
arg_parser.add_argument(
    "--tls-keyfile",
    dest="tls_keyfile",
    required=False,
    default=None,
    help="Path to the PEM encoded private key file for mTLS.",
)
arg_parser.add_argument(
    "--tls-hostname-override",
    dest="tls_hostname_override",
    required=False,
    default=None,
    help="The hostname to use for SSL/TLS certificate validation.",
)
# auth args
arg_parser.add_argument(
    "--credentials",
    dest="credentials",
    required=False,
    default=None,
    help="AVS credentials in 'user:password' format. Overrides --username and --password if provided.",
)
args = arg_parser.parse_args()

avs_username = None
avs_password = None

if args.credentials:
    parts = args.credentials.split(":", 1)
    avs_username = parts[0]
    if len(parts) > 1:
        avs_password = parts[1]
    else:
        logging.warning("--credentials provided but no password provided")


root_certificate = None
if args.tls_cafile:
    with open(args.tls_cafile, "rb") as f:
        root_certificate = f.read()

certificate_chain = None
if args.tls_certfile:
    with open(args.tls_certfile, "rb") as f:
        certificate_chain = f.read()

private_key = None
if args.tls_keyfile:
    with open(args.tls_keyfile, "rb") as f:
        private_key = f.read()

load_balancer = args.load_balancer
if args.no_load_balancer:
    load_balancer = False

try:
    with Client(
        seeds=types.HostPort(host=args.host, port=args.port),
        listener_name=listener_name,
        is_loadbalancer=load_balancer,
        username=avs_username,
        password=avs_password,
        root_certificate=root_certificate,
        certificate_chain=certificate_chain,
        private_key=private_key,
        ssl_target_name_override=args.tls_hostname_override,
    ) as client:
        
        print(f"load balancer: {load_balancer}")

        print("inserting vectors")
        for i in range(10):
            key = "r" + str(i)
            client.upsert(
                namespace=args.namespace,
                set_name=args.set,
                key=key,
                record_data={
                    "url": f"http://host.com/data{i}",
                    "vector": [i * 1.0, i * 1.0],
                    "map": {"a": "A", "inlist": [1, 2, 3]},
                    "list": ["a", 1, "c", {"a": "A"}],
                },
            )

        try:
            print("creating index")
            client.index_create(
                namespace=args.namespace,
                name=index_name,
                vector_field="vector",
                dimensions=2,
                mode=types.IndexMode.STANDALONE,
                sets=args.set,
                index_storage=types.IndexStorage(namespace=args.index_namespace, set_name=args.index_set),
            )
        except AVSServerError as e:
            print(f"failed creating index {e}, it may already exist, continuing...")
            pass

        # get an index object for easy querying
        index = client.index(
            namespace=args.namespace,
            name=index_name,
        )

        print("waiting for indexing to complete")
        wait_for_indexing(index)

        print("querying")
        for i in range(10):
            print("   query " + str(i))
            results = index.vector_search(
                query=[i * 1.0, i * 1.0],
                limit=10,
            )
            for result in results:
                print(str(result.key.key) + " -> " + str(result.fields))
except Exception as e:
    raise Exception(f"you are trying to connect to AVS on port {args.port}, "
          "on MacOS airplay uses port 5000 by default, make sure there is not a conflict") from e
