# Test Information

Pytest test suite for the AVS prism image search example application.
These tests are simple and used by the devs to verify the examples are functional.
They should not be used as a model for your production tests.

## Setup

Create a virtual environment and install the requirements in requirements.txt.
```shell
pip install -r requirements.txt
```

The tests use selenium with the chrome web driver so make sure that is installed on your system.

> [!IMPORTANT]
> Run the example app with the IMAGE_DIR environment variable pointing to your test image data. The CI tests use ../container-volumes/prism/images/static/data as it contains one image already.

Run the prism image search example app so that it listens on port 8080. If it is not running on port 8080, you will have to change the tests.

Then run the tests with pytest.
```shell
python -m pytest .
```