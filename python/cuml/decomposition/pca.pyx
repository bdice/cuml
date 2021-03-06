#
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

# cython: profile=False
# distutils: language = c++
# cython: embedsignature = True
# cython: language_level = 3

import ctypes
import cudf
import numpy as np

import rmm

import cuml

from libcpp cimport bool
from libc.stdint cimport uintptr_t

from cython.operator cimport dereference as deref

from cuml.common.array import CumlArray
from cuml.common.base import Base
from cuml.common.handle cimport cumlHandle
from cuml.decomposition.utils cimport *
import cuml.common.logger as logger
from cuml.common import input_to_cuml_array


cdef extern from "cuml/decomposition/pca.hpp" namespace "ML":

    cdef void pcaFit(cumlHandle& handle,
                     float *input,
                     float *components,
                     float *explained_var,
                     float *explained_var_ratio,
                     float *singular_vals,
                     float *mu,
                     float *noise_vars,
                     const paramsPCA &prms) except +

    cdef void pcaFit(cumlHandle& handle,
                     double *input,
                     double *components,
                     double *explained_var,
                     double *explained_var_ratio,
                     double *singular_vals,
                     double *mu,
                     double *noise_vars,
                     const paramsPCA &prms) except +

    cdef void pcaInverseTransform(cumlHandle& handle,
                                  float *trans_input,
                                  float *components,
                                  float *singular_vals,
                                  float *mu,
                                  float *input,
                                  const paramsPCA &prms) except +

    cdef void pcaInverseTransform(cumlHandle& handle,
                                  double *trans_input,
                                  double *components,
                                  double *singular_vals,
                                  double *mu,
                                  double *input,
                                  const paramsPCA &prms) except +

    cdef void pcaTransform(cumlHandle& handle,
                           float *input,
                           float *components,
                           float *trans_input,
                           float *singular_vals,
                           float *mu,
                           const paramsPCA &prms) except +

    cdef void pcaTransform(cumlHandle& handle,
                           double *input,
                           double *components,
                           double *trans_input,
                           double *singular_vals,
                           double *mu,
                           const paramsPCA &prms) except +


class PCA(Base):
    """
    PCA (Principal Component Analysis) is a fundamental dimensionality
    reduction technique used to combine features in X in linear combinations
    such that each new component captures the most information or variance of
    the data. N_components is usually small, say at 3, where it can be used for
    data visualization, data compression and exploratory analysis.

    cuML's PCA expects an array-like object or cuDF DataFrame, and provides 2
    algorithms Full and Jacobi. Full (default) uses a full eigendecomposition
    then selects the top K eigenvectors. The Jacobi algorithm is much faster
    as it iteratively tries to correct the top K eigenvectors, but might be
    less accurate.

    Examples
    ---------

    .. code-block:: python

        # Both import methods supported
        from cuml import PCA
        from cuml.decomposition import PCA

        import cudf
        import numpy as np

        gdf_float = cudf.DataFrame()
        gdf_float['0'] = np.asarray([1.0,2.0,5.0], dtype = np.float32)
        gdf_float['1'] = np.asarray([4.0,2.0,1.0], dtype = np.float32)
        gdf_float['2'] = np.asarray([4.0,2.0,1.0], dtype = np.float32)

        pca_float = PCA(n_components = 2)
        pca_float.fit(gdf_float)

        print(f'components: {pca_float.components_}')
        print(f'explained variance: {pca_float._explained_variance_}')
        exp_var = pca_float._explained_variance_ratio_
        print(f'explained variance ratio: {exp_var}')

        print(f'singular values: {pca_float._singular_values_}')
        print(f'mean: {pca_float._mean_}')
        print(f'noise variance: {pca_float._noise_variance_}')

        trans_gdf_float = pca_float.transform(gdf_float)
        print(f'Inverse: {trans_gdf_float}')

        input_gdf_float = pca_float.inverse_transform(trans_gdf_float)
        print(f'Input: {input_gdf_float}')

    Output:

    .. code-block:: python

          components:
                      0           1           2
                      0  0.69225764  -0.5102837 -0.51028395
                      1 -0.72165036 -0.48949987  -0.4895003

          explained variance:

                      0   8.510402
                      1 0.48959687

          explained variance ratio:

                       0   0.9456003
                       1 0.054399658

          singular values:

                     0 4.1256275
                     1 0.9895422

          mean:

                    0 2.6666667
                    1 2.3333333
                    2 2.3333333

          noise variance:

                0  0.0

          transformed matrix:
                       0           1
                       0   -2.8547091 -0.42891636
                       1 -0.121316016  0.80743366
                       2    2.9760244 -0.37851727

          Input Matrix:
                    0         1         2
                    0 1.0000001 3.9999993       4.0
                    1       2.0 2.0000002 1.9999999
                    2 4.9999995 1.0000006       1.0

    Parameters
    ----------
    copy : boolean (default = True)
        If True, then copies data then removes mean from data. False might
        cause data to be overwritten with its mean centered version.
    handle : cuml.Handle
        If it is None, a new one is created just for this class
    iterated_power : int (default = 15)
        Used in Jacobi solver. The more iterations, the more accurate, but
        slower.
    n_components : int (default = 1)
        The number of top K singular vectors / values you want.
        Must be <= number(columns).
    random_state : int / None (default = None)
        If you want results to be the same when you restart Python, select a
        state.
    svd_solver : 'full' or 'jacobi' or 'auto' (default = 'full')
        Full uses a eigendecomposition of the covariance matrix then discards
        components.
        Jacobi is much faster as it iteratively corrects, but is less accurate.
    tol : float (default = 1e-7)
        Used if algorithm = "jacobi". Smaller tolerance can increase accuracy,
        but but will slow down the algorithm's convergence.
    verbosity : int
        Logging level
    whiten : boolean (default = False)
        If True, de-correlates the components. This is done by dividing them by
        the corresponding singular values then multiplying by sqrt(n_samples).
        Whitening allows each component to have unit variance and removes
        multi-collinearity. It might be beneficial for downstream
        tasks like LinearRegression where correlated features cause problems.


    Attributes
    ----------
    components_ : array
        The top K components (VT.T[:,:n_components]) in U, S, VT = svd(X)
    explained_variance_ : array
        How much each component explains the variance in the data given by S**2
    explained_variance_ratio_ : array
        How much in % the variance is explained given by S**2/sum(S**2)
    singular_values_ : array
        The top K singular values. Remember all singular values >= 0
    mean_ : array
        The column wise mean of X. Used to mean - center the data first.
    noise_variance_ : float
        From Bishop 1999's Textbook. Used in later tasks like calculating the
        estimated covariance of X.

    Notes
    ------
    PCA considers linear combinations of features, specifically those that
    maximize global variance structure. This means PCA is fantastic for global
    structure analyses, but weak for local relationships. Consider UMAP or
    T-SNE for a locally important embedding.

    **Applications of PCA**

        PCA is used extensively in practice for data visualization and data
        compression. It has been used to visualize extremely large word
        embeddings like Word2Vec and GloVe in 2 or 3 dimensions, large
        datasets of everyday objects and images, and used to distinguish
        between cancerous cells from healthy cells.


    For additional docs, see `scikitlearn's PCA
    <http://scikit-learn.org/stable/modules/generated/sklearn.decomposition.PCA.html>`_.
    """

    def __init__(self, copy=True, handle=None, iterated_power=15,
                 n_components=1, random_state=None, svd_solver='auto',
                 tol=1e-7, verbosity=logger.LEVEL_INFO, whiten=False,
                 output_type=None):
        # parameters
        super(PCA, self).__init__(handle=handle, verbosity=verbosity,
                                  output_type=output_type)
        self.copy = copy
        self.iterated_power = iterated_power
        self.n_components = n_components
        self.random_state = random_state
        self.svd_solver = svd_solver
        self.tol = tol
        self.whiten = whiten
        self.c_algorithm = self._get_algorithm_c_name(self.svd_solver)

        # internal array attributes
        self._components_ = None  # accessed via estimator.components_
        self._trans_input_ = None  # accessed via estimator.trans_input_
        self._explained_variance_ = None
        # accessed via estimator.explained_variance_

        self._explained_variance_ratio_ = None
        # accessed via estimator.explained_variance_ratio_

        self._singular_values_ = None
        # accessed via estimator.singular_values_

        self._mean_ = None  # accessed via estimator.mean_
        self._noise_variance_ = None  # accessed via estimator.noise_variance_

    def _get_algorithm_c_name(self, algorithm):
        algo_map = {
            'full': COV_EIG_DQ,
            'auto': COV_EIG_DQ,
            # 'arpack': NOT_SUPPORTED,
            # 'randomized': NOT_SUPPORTED,
            'jacobi': COV_EIG_JACOBI
        }
        if algorithm not in algo_map:
            msg = "algorithm {!r} is not supported"
            raise TypeError(msg.format(algorithm))
        return algo_map[algorithm]

    def _build_params(self, n_rows, n_cols):
        cpdef paramsPCA *params = new paramsPCA()
        params.n_components = self.n_components
        params.n_rows = n_rows
        params.n_cols = n_cols
        params.whiten = self.whiten
        params.n_iterations = self.iterated_power
        params.tol = self.tol
        params.algorithm = self.c_algorithm

        return <size_t>params

    def _initialize_arrays(self, n_components, n_rows, n_cols):

        self._components_ = CumlArray.zeros((n_components, n_cols),
                                            dtype=self.dtype)
        self._explained_variance_ = CumlArray.zeros(n_components,
                                                    dtype=self.dtype)
        self._explained_variance_ratio_ = CumlArray.zeros(n_components,
                                                          dtype=self.dtype)
        self._mean_ = CumlArray.zeros(n_cols, dtype=self.dtype)

        self._singular_values_ = CumlArray.zeros(n_components,
                                                 dtype=self.dtype)
        self._noise_variance_ = CumlArray.zeros(1, dtype=self.dtype)

    def fit(self, X, y=None):
        """
        Fit the model with X.

        Parameters
        ----------
        X : array-like (device or host) shape = (n_samples, n_features)
            Dense matrix (floats or doubles) of shape (n_samples, n_features).
            Acceptable formats: cuDF DataFrame, NumPy ndarray, Numba device
            ndarray, cuda array interface compliant array like CuPy

        y : ignored

        Returns
        -------
        cluster labels

        """

        self._set_output_type(X)

        X_m, self.n_rows, self.n_cols, self.dtype = \
            input_to_cuml_array(X, check_dtype=[np.float32, np.float64])
        cdef uintptr_t input_ptr = X_m.ptr

        cdef paramsPCA *params = <paramsPCA*><size_t> \
            self._build_params(self.n_rows, self.n_cols)

        if self.n_components > self.n_cols:
            raise ValueError('Number of components should not be greater than'
                             'the number of columns in the data')

        self._initialize_arrays(params.n_components,
                                params.n_rows, params.n_cols)

        cdef uintptr_t comp_ptr = self._components_.ptr

        cdef uintptr_t explained_var_ptr = \
            self._explained_variance_.ptr

        cdef uintptr_t explained_var_ratio_ptr = \
            self._explained_variance_ratio_.ptr

        cdef uintptr_t singular_vals_ptr = \
            self._singular_values_.ptr

        cdef uintptr_t _mean_ptr = self._mean_.ptr

        cdef uintptr_t noise_vars_ptr = \
            self._noise_variance_.ptr

        cdef cumlHandle* handle_ = <cumlHandle*><size_t>self.handle.getHandle()
        if self.dtype == np.float32:
            pcaFit(handle_[0],
                   <float*> input_ptr,
                   <float*> comp_ptr,
                   <float*> explained_var_ptr,
                   <float*> explained_var_ratio_ptr,
                   <float*> singular_vals_ptr,
                   <float*> _mean_ptr,
                   <float*> noise_vars_ptr,
                   deref(params))
        else:
            pcaFit(handle_[0],
                   <double*> input_ptr,
                   <double*> comp_ptr,
                   <double*> explained_var_ptr,
                   <double*> explained_var_ratio_ptr,
                   <double*> singular_vals_ptr,
                   <double*> _mean_ptr,
                   <double*> noise_vars_ptr,
                   deref(params))

        # make sure the previously scheduled gpu tasks are complete before the
        # following transfers start
        self.handle.sync()

        return self

    def fit_transform(self, X, y=None):
        """
        Fit the model with X and apply the dimensionality reduction on X.

        Parameters
        ----------
        X : array-like (device or host) shape = (n_samples, n_features)
          training data (floats or doubles), where n_samples is the number of
          samples, and n_features is the number of features.
          Acceptable formats: cuDF DataFrame, NumPy ndarray, Numba device
          ndarray, cuda array interface compliant array like CuPy

        y : ignored

        Returns
        -------
        X_new : cuDF DataFrame, shape (n_samples, n_components)
        """

        return self.fit(X).transform(X)

    def inverse_transform(self, X, convert_dtype=False):
        """
        Transform data back to its original space.

        In other words, return an input X_original whose transform would be X.

        Parameters
        ----------
        X : array-like (device or host) shape = (n_samples, n_features)
            New data (floats or doubles), where n_samples is the number of
            samples and n_components is the number of components.
            Acceptable formats: cuDF DataFrame, NumPy ndarray, Numba device
            ndarray, cuda array interface compliant array like CuPy

        convert_dtype : bool, optional (default = False)
            When set to True, the inverse_transform method will automatically
            convert the input to the data type which was used to train the
            model. This will increase memory used for the method.

        Returns
        -------
        X_original : cuDF DataFrame, shape (n_samples, n_features)

        """
        out_type = self._get_output_type(X)

        X_m, n_rows, _, dtype = \
            input_to_cuml_array(X, check_dtype=self.dtype,
                                convert_to_dtype=(self.dtype if convert_dtype
                                                  else None)
                                )

        cdef uintptr_t _trans_input_ptr = X_m.ptr

        # todo: check n_cols and dtype
        cpdef paramsPCA params
        params.n_components = self.n_components
        params.n_rows = n_rows
        params.n_cols = self.n_cols
        params.whiten = self.whiten

        input_data = CumlArray.zeros((params.n_rows, params.n_cols),
                                     dtype=dtype.type)

        cdef uintptr_t input_ptr = input_data.ptr
        cdef uintptr_t components_ptr = self._components_.ptr
        cdef uintptr_t singular_vals_ptr = self._singular_values_.ptr
        cdef uintptr_t _mean_ptr = self._mean_.ptr

        cdef cumlHandle* h_ = <cumlHandle*><size_t>self.handle.getHandle()
        if dtype.type == np.float32:
            pcaInverseTransform(h_[0],
                                <float*> _trans_input_ptr,
                                <float*> components_ptr,
                                <float*> singular_vals_ptr,
                                <float*> _mean_ptr,
                                <float*> input_ptr,
                                params)
        else:
            pcaInverseTransform(h_[0],
                                <double*> _trans_input_ptr,
                                <double*> components_ptr,
                                <double*> singular_vals_ptr,
                                <double*> _mean_ptr,
                                <double*> input_ptr,
                                params)

        # make sure the previously scheduled gpu tasks are complete before the
        # following transfers start
        self.handle.sync()

        return input_data.to_output(out_type)

    def transform(self, X, convert_dtype=False):
        """
        Apply dimensionality reduction to X.

        X is projected on the first principal components previously extracted
        from a training set.

        Parameters
        ----------
        X : array-like (device or host) shape = (n_samples, n_features)
            New data (floats or doubles), where n_samples is the number of
            samples and n_components is the number of components.
            Acceptable formats: cuDF DataFrame, NumPy ndarray, Numba device
            ndarray, cuda array interface compliant array like CuPy

        convert_dtype : bool, optional (default = False)
            When set to True, the transform method will automatically
            convert the input to the data type which was used to train the
            model. This will increase memory used for the method.


        Returns
        -------
        X_new : cuDF DataFrame, shape (n_samples, n_components)

        """
        out_type = self._get_output_type(X)

        X_m, n_rows, n_cols, dtype = \
            input_to_cuml_array(X, check_dtype=self.dtype,
                                convert_to_dtype=(self.dtype if convert_dtype
                                                  else None),
                                check_cols=self.n_cols)

        cdef uintptr_t input_ptr = X_m.ptr

        # todo: check dtype
        cpdef paramsPCA params
        params.n_components = self.n_components
        params.n_rows = n_rows
        params.n_cols = n_cols
        params.whiten = self.whiten

        t_input_data = \
            CumlArray.zeros((params.n_rows, params.n_components),
                            dtype=dtype.type)

        cdef uintptr_t _trans_input_ptr = t_input_data.ptr
        cdef uintptr_t components_ptr = self._components_.ptr
        cdef uintptr_t singular_vals_ptr = \
            self._singular_values_.ptr
        cdef uintptr_t _mean_ptr = self._mean_.ptr

        cdef cumlHandle* handle_ = <cumlHandle*><size_t>self.handle.getHandle()
        if dtype.type == np.float32:
            pcaTransform(handle_[0],
                         <float*> input_ptr,
                         <float*> components_ptr,
                         <float*> _trans_input_ptr,
                         <float*> singular_vals_ptr,
                         <float*> _mean_ptr,
                         params)
        else:
            pcaTransform(handle_[0],
                         <double*> input_ptr,
                         <double*> components_ptr,
                         <double*> _trans_input_ptr,
                         <double*> singular_vals_ptr,
                         <double*> _mean_ptr,
                         params)

        # make sure the previously scheduled gpu tasks are complete before the
        # following transfers start
        self.handle.sync()

        return t_input_data.to_output(out_type)

    def get_param_names(self):
        return ["copy", "iterated_power", "n_components", "svd_solver", "tol",
                "whiten"]

    def __getstate__(self):
        state = self.__dict__.copy()
        # Remove the unpicklable handle.
        if 'handle' in state:
            del state['handle']

        return state

    def __setstate__(self, state):
        self.__dict__.update(state)
        self.handle = cuml.common.handle.Handle()
