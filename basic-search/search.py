import argparse

from aerospike_vector_search import Client, Index, types, AVSServerError

listener_name = None
index_name = "basic_index"

# Wait for the index to finish indexing records
def wait_for_indexing(index: Index):
    import time

    vertices = 0
    unmerged_recs = 0
    
    # Wait for the index to have vertices and no unmerged records
    while vertices == 0 or unmerged_recs > 0:
        status = index.status()

        vertices = status.index_healer_vertices_valid
        unmerged_recs = status.unmerged_record_count

        time.sleep(0.5)

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
args = arg_parser.parse_args()

try:
    with Client(
        seeds=types.HostPort(host=args.host, port=args.port),
        listener_name=listener_name,
        is_loadbalancer=args.load_balancer,
    ) as client:
        try:
            print("creating index")
            client.index_create(
                namespace=args.namespace,
                name=index_name,
                vector_field="vector",
                dimensions=2,
                sets=args.set,
                index_storage=types.IndexStorage(namespace=args.index_namespace, set_name=args.index_set),
            )
        except AVSServerError as e:
            print(f"failed creating index {e}, it may already exist, continuing...")
            pass

        index = client.index(
            namespace=args.namespace,
            name=index_name,
        )

        print("inserting vectors")
        for i in range(10):
            key = "r" + str(i)
            if not index.is_indexed(
                set_name=args.set, key=key
            ):
                # client is responsible for data operations
                # not the index object
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
