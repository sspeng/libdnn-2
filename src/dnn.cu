#include <dnn.h>
#include <dnn-utility.h>
#include <thrust/extrema.h>

DNN::DNN(): _transforms(), _dims() {}

DNN::DNN(string fn): _transforms(), _dims() {
  this->read(fn);
}

DNN::DNN(const std::vector<size_t>& dims): _transforms(), _dims(dims) {
  size_t L = _dims.size() - 1;

  _transforms.resize(L);

  for (size_t i=0; i<L; ++i) {
    size_t M = _dims[i] + 1;
    size_t N = _dims[i+1] + 1;

    if (i == L-1)
      _transforms[i] = new Softmax(M, N);
    else
      _transforms[i] = new AffineTransform(M, N);
  }
}

DNN::DNN(const DNN& source): _dims(source._dims), _transforms() {

  _transforms.resize(source._transforms.size());

  for (size_t i=0; i<_transforms.size(); ++i)
    *_transforms[i] = *source._transforms[i];
}

DNN& DNN::operator = (DNN rhs) {
  swap(*this, rhs);
  return *this;
}

DNN::~DNN() {
  for (size_t i=0; i<_transforms.size(); ++i)
    delete _transforms[i];
}

size_t DNN::getNLayer() const {
  return _dims.size(); 
}

size_t DNN::getDepth() const {
  return _dims.size() - 2;
}

#pragma GCC diagnostic ignored "-Wunused-result"
void readweight(FILE* fid, float* w, size_t rows, size_t cols) {

  for (size_t i=0; i<rows - 1; ++i)
    for (size_t j=0; j<cols; ++j)
      fscanf(fid, "%f ", &(w[j * rows + i]));

  fscanf(fid, "]\n<sigmoid>\n [");

  for (size_t j=0; j<cols; ++j)
    fscanf(fid, "%f ", &(w[j * rows + rows - 1]));
  fscanf(fid, "]\n");

}

#pragma GCC diagnostic ignored "-Wunused-result"
void DNN::read(string fn) {
  FILE* fid = fopen(fn.c_str(), "r");

  _dims.clear();
  _transforms.clear();

  size_t rows, cols;
  char type[80];

  while (fscanf(fid, "%s", type) != EOF) {
    fscanf(fid, "%lu %lu\n [\n", &rows, &cols);
    printf("%s: rows = %lu, cols = %lu \n", type, rows, cols);

    float* hw = new float[(rows + 1) * (cols + 1)];
    readweight(fid, hw, rows + 1, cols);

    // Reserve one more column for bias)
    mat w(hw, rows + 1, cols + 1);

    string transformType = string(type);
    if (transformType == "<affinetransform>")
      _transforms.push_back(new AffineTransform(w));
    else if (transformType == "<softmax>")
      _transforms.push_back(new Softmax(w));

    delete [] hw;

    _dims.push_back(rows);
  }
  _dims.push_back(cols);

  fclose(fid);
}

void DNN::save(string fn) const {
  FILE* fid = fopen(fn.c_str(), "w");

  for (size_t i=0; i<_transforms.size(); ++i) {
    const mat& w = _transforms[i]->getW();

    size_t rows = w.getRows();
    size_t cols = w.getCols() - 1;

    fprintf(fid, "<%s> %lu %lu \n", _transforms[i]->toString().c_str(), rows - 1, cols);
    fprintf(fid, " [");

    // ==============================
    float* data = new float[w.size()];
    CCE(cudaMemcpy(data, w.getData(), sizeof(float) * w.size(), cudaMemcpyDeviceToHost));

    for (size_t j=0; j<rows-1; ++j) {
      fprintf(fid, "\n  ");
      for (size_t k=0; k<cols; ++k)
	fprintf(fid, "%g ", data[k * rows + j]);
    }
    fprintf(fid, "]\n");

    fprintf(fid, "<sigmoid> \n [");
    for (size_t j=0; j<cols; ++j)
      fprintf(fid, "%g ", data[j * rows + rows - 1]);
    fprintf(fid, " ]\n");

    delete [] data;
  }

  fprintf(stdout, "nn_structure ");
  for (size_t i=0; i<_dims.size(); ++i)
    fprintf(stdout, "%lu ", _dims[i]);
  fprintf(stdout, "\n");
  
  fclose(fid);
}

void DNN::print() const {
  for (size_t i=0; i<_transforms.size(); ++i)
    _transforms[i]->getW().print();
}

// ========================
// ===== Feed Forward =====
// ========================

void print(const thrust::host_vector<float>& hv) {
  cout << "\33[33m[";
  for (size_t i=0; i<hv.size(); ++i)
    cout << hv[i] << " ";
  cout << " ] \33[0m" << endl << endl;
}

void print(const mat& m) {
  thrust::device_ptr<float> dm(m.getData());
  thrust::host_vector<float> hm(dm, dm + m.size());

  ::print(hm);
}

void print(const thrust::device_vector<float>& dv) {
  thrust::host_vector<float> hv(dv.begin(), dv.end());
  ::print(hv);
}

void DNN::train(const DataSet& train, const DataSet& valid, size_t batchSize, ERROR_MEASURE errorMeasure) {

  printf("Training...\n");
  perf::Timer timer;
  timer.start();

  vector<mat> O(this->getNLayer());

  size_t Ein, Eout;
  size_t prevEout = valid.y.size();
  size_t MAX_EPOCH = 1024, epoch;

  size_t nTrain = train.X.getRows(),
	 nValid = valid.X.getRows();

  size_t nBatch = nTrain / batchSize,
         remained = nTrain - nBatch * batchSize;

  if (remained > 0)
    ++nBatch;

  for (epoch=0; epoch<MAX_EPOCH; ++epoch) {
    cout << "."; cout.flush();

    for (size_t b=0; b<nBatch; ++b) {

      size_t offset = b*batchSize;
      size_t nData = batchSize;

      if (b == nBatch - 1)
	nData = min(remained - 1, batchSize);

      this->feedForward(train, O, offset, nData);

      mat error = this->getError(train.prob, O.back(), offset, nData, errorMeasure);

      this->backPropagate(train, O, error, offset, nData);
      this->updateParameters(1e-1);
    }

    this->feedForward(valid, O);
    Eout = zeroOneError(O.back(), valid.y, errorMeasure);

    if (Eout > prevEout && (float) Eout / nValid < 0.2)
      break;

    prevEout = Eout;
  }

  // Show Summary
  printf("\n%d epochs in total\n", epoch);
  timer.elapsed();

  this->feedForward(train, O);
  Ein = zeroOneError(O.back(), train.y, errorMeasure);

  printf("[   In-Sample   ] ");
  showAccuracy(Ein, train.y.size());
  printf("[ Out-of-Sample ] ");
  showAccuracy(Eout, valid.y.size());
}

mat DNN::predict(const DataSet& test) {
  vector<mat> O(this->getNLayer());
  this->feedForward(test, O);
  return O.back();
}

mat DNN::getError(const mat& target, const mat& output, size_t offset, size_t batchSize, ERROR_MEASURE errorMeasure) {

  mat error;

  mat& O = const_cast<mat&>(output);

  switch (errorMeasure) {
    case L2ERROR: 
      // mat error = O.back() - train.y;
      error = calcError(O, target, offset, batchSize);
      error.reserve(error.getRows() * (error.getCols() + 1));
      error.resize(error.getRows(), error.getCols() + 1);

      break;
    case CROSS_ENTROPY: {

	size_t output_dim = target.getCols();

	error.resize(batchSize, output_dim + 1);

	mat batchTarget(batchSize, output_dim);
	memcpy2D(batchTarget, target, offset, 0, batchSize, output_dim, 0, 0);

	thrust::device_ptr<float> pPtr(batchTarget.getData());
	thrust::device_ptr<float> oPtr(O.getData());

	thrust::device_ptr<float> ePtr(error.getData());

	thrust::device_vector<float> TMP(O.size());
	thrust::transform(oPtr, oPtr + O.size(), TMP.begin(), func::min_threshold<float>(0.001));

	// matlog(O);
	// matlog(batchTarget);

	thrust::transform(pPtr, pPtr + batchTarget.size(), TMP.begin(), ePtr, func::dcrossentropy<float>());

	// printf("error = batchTarget ./ O \n");
	// matlog(error);
	// PAUSE;

	break;
      }

    default:
      break;
  }

  O.resize(O.getRows(), O.getCols() + 1);

  return error;
}

void DNN::feedForward(const DataSet& data, std::vector<mat>& O, size_t offset, size_t batchSize) {
  assert(batchSize >= 0 && offset + batchSize <= data.X.getRows());

  // All data in one-batch (Gradient Descent)
  if (batchSize == 0)
    batchSize = data.X.getRows();

  assert(O.size() == _dims.size());

  O[0].resize(batchSize, data.X.getCols());
  memcpy2D(O[0], data.X, offset, 0, batchSize, data.X.getCols(), 0, 0);

  for (size_t i=0; i<_transforms.size(); ++i)
    _transforms[i]->feedForward(O[i+1], O[i], offset, batchSize);

  O.back().resize(O.back().getRows(), O.back().getCols() - 1);
}

// ============================
// ===== Back Propagation =====
// ============================

void DNN::backPropagate(const DataSet& data, std::vector<mat>& O, mat& error, size_t offset, size_t batchSize) {

  for (int i=_transforms.size() - 1; i >= 0; --i)
    _transforms[i]->backPropagate(O[i], O[i+1], error);
}

void DNN::updateParameters(float learning_rate) { 
  for (size_t i=0; i<_transforms.size(); ++i)
    _transforms[i]->update(learning_rate);
}

void swap(DNN& lhs, DNN& rhs) {
  using WHERE::swap;
  swap(lhs._dims, rhs._dims);
  swap(lhs._transforms, rhs._transforms);
}

// =============================
// ===== Utility Functions =====
// =============================

mat l2error(mat& targets, mat& predicts) {
  mat err(targets - predicts);

  thrust::device_ptr<float> ptr(err.getData());
  thrust::transform(ptr, ptr + err.size(), ptr, func::square<float>());

  mat sum_matrix(err.getCols(), 1);
  err *= sum_matrix;
  
  return err;
}
