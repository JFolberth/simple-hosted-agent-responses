FROM myoung34/github-runner:ubuntu-noble

# Install Azure CLI — required by azure/login@v3 and all az calls in composite actions
RUN curl -sL https://aka.ms/InstallAzureCLIDeb | bash \
 && az --version | head -1

# skopeo pushes images to ACR without a Docker daemon, which ACA does not provide
RUN apt-get update \
 && apt-get install -y --no-install-recommends skopeo \
 && rm -rf /var/lib/apt/lists/* \
 && skopeo --version
