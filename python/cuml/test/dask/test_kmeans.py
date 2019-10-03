# Copyright (c) 2019, NVIDIA CORPORATION.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

import pytest
from dask_cuda import LocalCUDACluster

from dask.distributed import Client, wait

import numpy as np

from cuml.test.utils import array_equal


@pytest.mark.mg
@pytest.mark.parametrize("nrows", [1e3, 1e5, 5e5])
@pytest.mark.parametrize("ncols", [10, 30])
@pytest.mark.parametrize("nclusters", [5, 10])
@pytest.mark.parametrize("n_parts", [None, 1, 50])
def test_end_to_end(nrows, ncols, nclusters, n_parts, client=None):

    owns_cluster = False
    if client is None:
        owns_cluster = True
        cluster = LocalCUDACluster(threads_per_worker=1)
        client = Client(cluster)

    from cuml.dask.cluster import KMeans as cumlKMeans

    from cuml.dask.datasets import make_blobs

    X_cudf, y = make_blobs(nrows, ncols, nclusters, n_parts,
                           cluster_std=0.01, verbose=True,
                           random_state=10)

    cumlModel = cumlKMeans(verbose=0, init="k-means||", n_clusters=nclusters,
                           random_state=10)

    cumlModel.fit(X_cudf)

    cumlLabels = cumlModel.predict(X_cudf)

    n_workers = len(list(client.has_what().keys()))

    # Verifying we are grouping partitions. This should be changed soon.
    if n_parts is not None and n_parts < n_workers:
        assert cumlLabels.npartitions == n_parts
    else:
        assert cumlLabels.npartitions == n_workers

    from sklearn.metrics import adjusted_rand_score

    cumlPred = cumlLabels.compute().to_pandas().values

    assert cumlPred.shape[0] == nrows
    assert np.max(cumlPred) == nclusters-1
    assert np.min(cumlPred) == 0

    labels = y.compute().to_pandas().values

    score = adjusted_rand_score(labels.reshape(labels.shape[0]), cumlPred)

    if owns_cluster:
        client.close()
        cluster.close()

    assert 1.0 == score


@pytest.mark.mg
@pytest.mark.parametrize("nrows", [100, 500])
@pytest.mark.parametrize("ncols", [10, 30, 50])
@pytest.mark.parametrize("nclusters", [1, 5, 10, 100])
@pytest.mark.parametrize("n_parts", [None, 5])
def test_transform(nrows, ncols, nclusters, n_parts, client=None):

    owns_cluster = False
    if client is None:
        owns_cluster = True
        cluster = LocalCUDACluster(threads_per_worker=1)
        client = Client(cluster)

    from cuml.dask.cluster import KMeans as cumlKMeans

    from cuml.dask.datasets import make_blobs

    X_cudf, y = make_blobs(nrows, ncols, nclusters, n_parts,
                           cluster_std=0.01, verbose=True,
                           random_state=10)

    cumlModel = cumlKMeans(verbose=0, init="k-means||", n_clusters=nclusters,
                           random_state=10)

    cumlModel.fit(X_cudf)

    labels = y.compute().to_pandas().values
    labels = labels.reshape(labels.shape[0])

    xformed = cumlModel.transform(X_cudf).compute()

    assert xformed.shape == (nrows, nclusters)

    # The argmin of the transformed values should be equal to the labels
    xformed_labels = np.argmin(xformed.to_pandas().to_numpy(), axis=1)

    from sklearn.metrics import adjusted_rand_score
    assert adjusted_rand_score(labels, xformed_labels)

    if owns_cluster:
        client.close()
        cluster.close()
