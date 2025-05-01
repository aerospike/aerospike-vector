from aerospike_vector_search import Client, types

from config import Config

seeds = types.HostPort(
    host=Config.AVS_HOST,
    port=Config.AVS_PORT,
)

avs_client = Client(
    seeds=seeds,
    username=Config.AVS_AUTH_USERNAME,
    password=Config.AVS_AUTH_PASSWORD,
    root_certificate=Config.AVS_TLS_CA,
    certificate_chain=Config.AVS_TLS_CERT,
    private_key=Config.AVS_TLS_KEY,
    listener_name=Config.AVS_ADVERTISED_LISTENER,
    is_loadbalancer=Config.AVS_IS_LOADBALANCER,
    ssl_target_name_override=Config.AVS_TLS_NAME_OVERRIDE,
)
