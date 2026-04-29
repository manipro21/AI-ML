FROM python:3.12.9-slim

RUN apt-get update && apt-get install -y git curl build-essential ca-certificates
RUN mkdir -p /logs

RUN git init /testbed
WORKDIR /testbed
RUN git remote add origin https://github.com/PrefectHQ/fastmcp.git
RUN git fetch --depth 1 origin 6c76bea3e840bbe75dbddb167a8f9ecda410e8b9 || \
    (sleep 2 && git fetch --depth 1 origin 6c76bea3e840bbe75dbddb167a8f9ecda410e8b9) || \
    (sleep 5 && git fetch --depth 1 origin 6c76bea3e840bbe75dbddb167a8f9ecda410e8b9)
RUN git checkout 6c76bea3e840bbe75dbddb167a8f9ecda410e8b9
RUN rm -rf /testbed/.git

COPY constraints.txt /testbed/constraints.txt
RUN PIP_CONSTRAINT=/testbed/constraints.txt pip install -e .

RUN curl -LsSf https://astral.sh/uv/0.7.13/install.sh | sh
ENV PATH="/root/.local/bin:$PATH"
