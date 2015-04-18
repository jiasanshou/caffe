#include <algorithm>
#include <cfloat>
#include <vector>

#include "thrust/device_vector.h"

#include "caffe/layer.hpp"
#include "caffe/util/math_functions.hpp"
#include "caffe/vision_layers.hpp"

#ifdef USE_GREENTEA
#include "caffe/greentea/greentea_math_functions.hpp"
#include "caffe/greentea/greentea_im2col.hpp"
#endif

namespace caffe {

template<typename Dtype>
__global__ void kernel_channel_max(const int num, const int channels,
                                   const int spatial_dim, const Dtype* data,
                                   Dtype* out) {
  CUDA_KERNEL_LOOP(index, num * spatial_dim)
  {
    int n = index / spatial_dim;
    int s = index % spatial_dim;
    Dtype maxval = -FLT_MAX;
    for (int c = 0; c < channels; ++c) {
      maxval = max(data[(n * channels + c) * spatial_dim + s], maxval);
    }
    out[index] = maxval;
  }
}

template<typename Dtype>
__global__ void kernel_channel_subtract(const int count, const int num,
                                        const int channels,
                                        const int spatial_dim,
                                        const Dtype* channel_max, Dtype* data) {
  CUDA_KERNEL_LOOP(index, count)
  {
    int n = index / channels / spatial_dim;
    int s = index % spatial_dim;
    data[index] -= channel_max[n * spatial_dim + s];
  }
}

template<typename Dtype>
__global__ void kernel_exp(const int count, const Dtype* data, Dtype* out) {
  CUDA_KERNEL_LOOP(index, count)
  {
    out[index] = exp(data[index]);
  }
}

template<typename Dtype>
__global__ void kernel_channel_sum(const int num, const int channels,
                                   const int spatial_dim, const Dtype* data,
                                   Dtype* channel_sum) {
  CUDA_KERNEL_LOOP(index, num * spatial_dim)
  {
    int n = index / spatial_dim;
    int s = index % spatial_dim;
    Dtype sum = 0;
    for (int c = 0; c < channels; ++c) {
      sum += data[(n * channels + c) * spatial_dim + s];
    }
    channel_sum[index] = sum;
  }
}

template<typename Dtype>
__global__ void kernel_channel_div(const int count, const int num,
                                   const int channels, const int spatial_dim,
                                   const Dtype* channel_sum, Dtype* data) {
  CUDA_KERNEL_LOOP(index, count)
  {
    int n = index / channels / spatial_dim;
    int s = index % spatial_dim;
    data[index] /= channel_sum[n * spatial_dim + s];
  }
}

template<typename Dtype>
__global__ void kernel_channel_dot(const int num, const int channels,
                                   const int spatial_dim, const Dtype* data_1,
                                   const Dtype* data_2, Dtype* channel_dot) {
  CUDA_KERNEL_LOOP(index, num * spatial_dim)
  {
    int n = index / spatial_dim;
    int s = index % spatial_dim;
    Dtype dot = 0;
    for (int c = 0; c < channels; ++c) {
      dot += (data_1[(n * channels + c) * spatial_dim + s]
          * data_2[(n * channels + c) * spatial_dim + s]);
    }
    channel_dot[index] = dot;
  }
}

template<typename Dtype>
void SoftmaxLayer<Dtype>::Forward_gpu(const vector<Blob<Dtype>*>& bottom,
                                      const vector<Blob<Dtype>*>& top) {

  if (this->device_context_.backend() == BACKEND_CUDA) {
    // CUDA backend code
    const Dtype* bottom_data = bottom[0]->gpu_data();
    Dtype* top_data = top[0]->mutable_gpu_data();
    Dtype* scale_data = scale_.mutable_gpu_data();
    int count = bottom[0]->count();
    int num = bottom[0]->num();
    int channels = bottom[0]->channels();
    int spatial_dim = bottom[0]->height() * bottom[0]->width();
    caffe_copy(count, bottom_data, top_data);
    // We need to subtract the max to avoid numerical issues, compute the exp,
    // and then normalize.
    // compute max
    // NOLINT_NEXT_LINE(whitespace/operators)
  kernel_channel_max<Dtype><<<CAFFE_GET_BLOCKS(num * spatial_dim),
  CAFFE_CUDA_NUM_THREADS>>>(num, channels, spatial_dim, top_data,
      scale_data);
    // subtract
    // NOLINT_NEXT_LINE(whitespace/operators)
  kernel_channel_subtract<Dtype><<<CAFFE_GET_BLOCKS(count),
  CAFFE_CUDA_NUM_THREADS>>>(count, num, channels, spatial_dim,
      scale_data, top_data);
    // exponentiate
    // NOLINT_NEXT_LINE(whitespace/operators)
  kernel_exp<Dtype><<<CAFFE_GET_BLOCKS(num * channels * spatial_dim),
  CAFFE_CUDA_NUM_THREADS>>>(num * channels * spatial_dim, top_data,
      top_data);
    // sum after exp
    // NOLINT_NEXT_LINE(whitespace/operators)
  kernel_channel_sum<Dtype><<<CAFFE_GET_BLOCKS(num * spatial_dim),
  CAFFE_CUDA_NUM_THREADS>>>(num, channels, spatial_dim, top_data,
      scale_data);
    // divide
    // NOLINT_NEXT_LINE(whitespace/operators)
  kernel_channel_div<Dtype><<<CAFFE_GET_BLOCKS(count),
  CAFFE_CUDA_NUM_THREADS>>>(count, num, channels, spatial_dim,
      scale_data, top_data);

} else {
#ifdef USE_GREENTEA
  viennacl::ocl::context &ctx = viennacl::ocl::get_context(
      this->device_context_.id());
  viennacl::ocl::program &program = Caffe::Get().GetDeviceProgram(
      this->device_context_.id());

  const cl_mem bottom_data = (cl_mem) (bottom[0]->gpu_data());
  cl_mem top_data = (cl_mem) (top[0]->mutable_gpu_data());
  cl_mem scale_data = (cl_mem) (scale_.mutable_gpu_data());
  int count = bottom[0]->count();
  int num = bottom[0]->num();
  int channels = bottom[0]->channels();
  int spatial_dim = bottom[0]->height() * bottom[0]->width();

  greentea_copy<Dtype>(count, bottom_data, top_data, ctx);

  viennacl::ocl::kernel &oclk_channel_max = program.get_kernel(
      CL_KERNEL_SELECT("kernel_channel_max"));
  viennacl::ocl::enqueue(
      oclk_channel_max(num, channels, spatial_dim, WrapVector<Dtype>(top_data),
                       WrapVector<Dtype>(scale_data)),
      ctx.get_queue());
  ctx.get_queue().finish();

  viennacl::ocl::kernel &oclk_channel_subtract = program.get_kernel(
      CL_KERNEL_SELECT("kernel_channel_subtract"));
  viennacl::ocl::enqueue(
      oclk_channel_subtract(count, num, channels, spatial_dim,
                            WrapVector<Dtype>(scale_data),
                            WrapVector<Dtype>(top_data)),
      ctx.get_queue());
  ctx.get_queue().finish();

  viennacl::ocl::kernel &oclk_exp = program.get_kernel(
      CL_KERNEL_SELECT("kernel_exp"));
  viennacl::ocl::enqueue(
      oclk_exp(num * channels * spatial_dim, WrapVector<Dtype>(top_data),
               WrapVector<Dtype>(top_data)),
      ctx.get_queue());
  ctx.get_queue().finish();

  viennacl::ocl::kernel &oclk_channel_sum = program.get_kernel(
      CL_KERNEL_SELECT("kernel_channel_sum"));
  viennacl::ocl::enqueue(
      oclk_channel_sum(num, channels, spatial_dim, WrapVector<Dtype>(top_data),
                       WrapVector<Dtype>(scale_data)),
      ctx.get_queue());
  ctx.get_queue().finish();

  viennacl::ocl::kernel &oclk_channel_div = program.get_kernel(
      CL_KERNEL_SELECT("kernel_channel_div"));
  viennacl::ocl::enqueue(
      oclk_channel_div(count, num, channels, spatial_dim,
                       WrapVector<Dtype>(scale_data),
                       WrapVector<Dtype>(top_data)),
      ctx.get_queue());
  ctx.get_queue().finish();

#endif
}
}

template<typename Dtype>
void SoftmaxLayer<Dtype>::Backward_gpu(const vector<Blob<Dtype>*>& top,
                                       const vector<bool>& propagate_down,
                                       const vector<Blob<Dtype>*>& bottom) {
  const Dtype* top_diff = top[0]->gpu_diff();
  const Dtype* top_data = top[0]->gpu_data();
  Dtype* bottom_diff = bottom[0]->mutable_gpu_diff();
  Dtype* scale_data = scale_.mutable_gpu_data();
  int count = top[0]->count();
  int num = top[0]->num();
  int channels = top[0]->channels();
  int spatial_dim = top[0]->height() * top[0]->width();
  caffe_copy(top[0]->count(), top_diff, bottom_diff);
  // Compute inner1d(top_diff, top_data) and subtract them from the bottom diff.
  // NOLINT_NEXT_LINE(whitespace/operators)
  kernel_channel_dot<Dtype><<<CAFFE_GET_BLOCKS(num * spatial_dim),
  CAFFE_CUDA_NUM_THREADS>>>(num, channels, spatial_dim, top_diff, top_data,
      scale_data);
  // NOLINT_NEXT_LINE(whitespace/operators)
  kernel_channel_subtract<Dtype><<<CAFFE_GET_BLOCKS(count),
  CAFFE_CUDA_NUM_THREADS>>>(count, num, channels, spatial_dim,
      scale_data, bottom_diff);
  // elementwise multiplication
  caffe_gpu_mul<Dtype>(top[0]->count(), bottom_diff, top_data, bottom_diff);
}

INSTANTIATE_LAYER_GPU_FUNCS(SoftmaxLayer);

}  // namespace caffe
