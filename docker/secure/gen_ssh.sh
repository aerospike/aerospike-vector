#!/bin/bash

DEST="config/tls"

# Create the directory for the cert files
mkdir -p ${DEST}

# --- Generate CA Key and Certificate ---
echo "Generating CA key and certificate..."
openssl genrsa -out ${DEST}/ca.key 2048
# Use a subject for the CA certificate
openssl req -new -x509 -days 3650 -key ${DEST}/ca.key -out ${DEST}/ca.crt -subj "/CN=TestCA"

# --- Generate Server Key and Certificate for AVS ---
echo "Generating AVS server key and certificate..."
openssl genrsa -out ${DEST}/server.key 2048
# Create CSR for the server - Use a distinct CN, e.g., avs.server
openssl req -new -key ${DEST}/server.key -out ${DEST}/server.csr -subj "/CN=avs.server"
# Sign the server CSR with the CA, adding Subject Alternative Names (SANs)
# This allows clients to connect via localhost, 127.0.0.1, or avs.server
openssl x509 -req -days 365 -in ${DEST}/server.csr \
    -CA ${DEST}/ca.crt -CAkey ${DEST}/ca.key -CAcreateserial \
    -out ${DEST}/server.crt \
    -extfile <(printf "subjectAltName=DNS:avs.server,DNS:localhost,IP:127.0.0.1")

# --- Generate Client Key and Certificate for search.py ---
echo "Generating search.py client key and certificate..."
openssl genrsa -out ${DEST}/client.key 2048
# Create CSR for the client - Use a distinct CN, e.g., search.py.client
openssl req -new -key ${DEST}/client.key -out ${DEST}/client.csr -subj "/CN=search.py.client"
# Sign the client CSR with the CA
openssl x509 -req -days 365 -in ${DEST}/client.csr -CA ${DEST}/ca.crt -CAkey ${DEST}/ca.key -CAcreateserial -out ${DEST}/client.crt

# --- Clean up CSRs and CA serial file ---
echo "Cleaning up intermediate files..."
rm ${DEST}/server.csr
rm ${DEST}/client.csr
rm ${DEST}/ca.srl # openssl may create this file

echo "Certificates and Keystores generated in ${DEST}/ directory:"
echo "  CA: ca.key, ca.crt"
echo "  Server (AVS): server.key, server.crt"
echo "  Client (search.py): client.key, client.crt"
echo "  Server Keystore (for AVS): server_keystore.jks (contains server key/cert + CA cert)"
