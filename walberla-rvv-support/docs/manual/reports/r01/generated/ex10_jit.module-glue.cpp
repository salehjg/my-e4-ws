struct KernelArgs_kernel
{
   const double* RESTRICT _data_f;
   double* RESTRICT _data_g;
   int64_t _size_f_0;
   int64_t _size_f_1;
   int64_t _stride_f_0;
   int64_t _stride_f_1;
   int64_t _stride_g_0;
   int64_t _stride_g_1;

   KernelArgs_kernel(PyObject* posargs, PyObject* kwargs)
   {
      //  Extract borrowed references to required kwargs
      PyObject* _ref_f = getKwarg(kwargs, "f");
      PyObject* _ref_g = getKwarg(kwargs, "g");

      //  Convert arrays to ArrayProxy
      ArrayProxy array_proxy_f =
          ArrayProxy::fromPyObject("f", _ref_f, 2, NPY_FLOAT64, 8);
      ArrayProxy array_proxy_g =
          ArrayProxy::fromPyObject("g", _ref_g, 2, NPY_FLOAT64, 8);

      //  Extract scalar kernel arguments
      _data_f = array_proxy_f.data<double>();
      _data_g = array_proxy_g.data<double>();
      _size_f_0 = array_proxy_f.shape<int64_t>(0);
      _size_f_1 = array_proxy_f.shape<int64_t>(1);
      _stride_f_0 = array_proxy_f.stride<int64_t>(0);
      _stride_f_1 = array_proxy_f.stride<int64_t>(1);
      _stride_g_0 = array_proxy_g.stride<int64_t>(0);
      _stride_g_1 = array_proxy_g.stride<int64_t>(1);

      //  Check preconditions
      checkTrivialIndexShape("(*, *)", array_proxy_f, 2);
      checkTrivialIndexShape("(*, *)", array_proxy_g, 2);
      checkSameShape({&array_proxy_f, &array_proxy_g}, 2);
   }
};

extern "C"
{
   static PyObject* invoke(PyObject* module, PyObject* posargs, PyObject* kwargs)
   {
      try
      {
         KernelArgs_kernel kernel_args{posargs, kwargs};
         internal::kernel(kernel_args._data_f, kernel_args._data_g,
                          kernel_args._size_f_0, kernel_args._size_f_1,
                          kernel_args._stride_f_0, kernel_args._stride_f_1,
                          kernel_args._stride_g_0, kernel_args._stride_g_1);
      }
      catch (const KernelModuleError& err)
      {
         PyErr_SetString(err.exception, err.msg.c_str());
         return NULL;
      }
      catch (const PythonError& err)
      {
         //   Error condition was set by Python API - nothing to do
         return NULL;
      }

      Py_RETURN_NONE;
   }
