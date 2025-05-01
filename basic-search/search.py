import argparse
import time

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
# tls args
arg_parser.add_argument(
    "--root-certificate",
    dest="root_certificate",
    required=False,
    default=None,
    help="Path to the PEM encoded root certificate file.",
)
arg_parser.add_argument(
    "--certificate-chain",
    dest="certificate_chain",
    required=False,
    default=None,
    help="Path to the PEM encoded certificate chain file.",
)
arg_parser.add_argument(
    "--private-key",
    dest="private_key",
    required=False,
    default=None,
    help="Path to the PEM encoded private key file.",
)
arg_parser.add_argument(
    "--ssl-target-name-override",
    dest="ssl_target_name_override",
    required=False,
    default=None,
    help="The hostname to use for the SSL connection.",
)
# auth args
arg_parser.add_argument(
    "--username",
    dest="username",
    required=False,
    default=None,
    help="Username for basic auth.",
)
arg_parser.add_argument(
    "--password",
    dest="password",
    required=False,
    default=None,
    help="Password for basic auth.",
)
args = arg_parser.parse_args()

root_certificate = None
if args.root_certificate:
    with open(args.root_certificate, "rb") as f:
        root_certificate = f.read()

certificate_chain = None
if args.certificate_chain:
    with open(args.certificate_chain, "rb") as f:
        certificate_chain = f.read()

private_key = None
if args.private_key:
    with open(args.private_key, "rb") as f:
        private_key = f.read()

try:
    with Client(
        seeds=types.HostPort(host=args.host, port=args.port),
        listener_name=listener_name,
        is_loadbalancer=args.load_balancer,
        username=args.username,
        password=args.password,
        root_certificate=root_certificate,
        certificate_chain=certificate_chain,
        private_key=private_key,
        ssl_target_name_override=args.ssl_target_name_override,
    ) as client:
        
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
