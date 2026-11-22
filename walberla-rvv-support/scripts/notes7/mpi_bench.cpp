// notes7: mpi_bench, a small MPI test with knobs (monte3.sh mode "mpitest", or by hand).
//
// It runs communication patterns at several message sizes, checks every received byte and prints one result
// line per step. With --trace every rank also prints when it enters and leaves a step, so when a run hangs,
// the output shows which ranks are stuck in which step (monte3.sh turns that into a sentence).
//
// Build: mpicxx -O2 -std=c++17 -o mpi_bench mpi_bench.cpp
// Run:   mpirun -np 16 ./mpi_bench --pattern halo --bytes 64K,1M --repeats 100
//
// Patterns (--pattern, comma-separated, default all of them in this order):
//   ring       exchange with both ring neighbours at once (Irecv, Isend, Waitall)
//   halo       the processes form a 3D grid (MPI_Dims_create, not periodic), like waLBerla's blocks; each one
//              exchanges with its face and edge neighbours at once (up to 18, the D3Q19 directions), every
//              message --bytes long: the pattern of waLBerla's halo exchange
//   alltoall   MPI_Alltoall, --bytes per pair of processes (skipped above 64 MiB per process)
//   allreduce  MPI_Allreduce (sum) of --bytes of doubles
//   barrier    MPI_Barrier (message size does not apply: one step only)
// Options:
//   --bytes LIST     message sizes, e.g. 1K,64K,1M (K = 1024, M = 1024^2); default 1K,16K,64K,256K,1M
//   --repeats N      timed repetitions per step (default 20)
//   --seconds S      instead of --repeats: as many repetitions as fit in about S seconds per step
//   --warmup N       untimed repetitions before (default 2; they also calibrate --seconds)
//   --no-check       do not check the received data
//   --trace          every rank prints "trace rank=<r> <pattern> bytes=<n> enter|leave"
// Output (rank 0): "mpi_bench start ...", one "mpi_bench pattern=..." line per step, "mpi_bench done ... errors=E".
// At the end rank 0 also prints the CPU time of each of its own threads as a share of the run (since the end of
// MPI_Init), read from /proc/self/task (this process's own entries, nothing else), and over all ranks the busiest
// helper thread: one near 100 % spins and competes with the rank for its core (monte3's system Open MPI 4.1.5
// did; /proc counts in clock ticks, usually 10 ms, so very short runs read coarsely).
// Exit code: 0 if every received byte was right, 1 if not, 2 for a wrong option.
#include <dirent.h>
#include <mpi.h>
#include <sched.h>
#include <unistd.h>

#include <algorithm>
#include <array>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <iterator>
#include <sstream>
#include <string>
#include <vector>

namespace {

int rank = 0;
int size = 1;

struct Options
{
   std::vector<std::string> patterns{ "ring", "halo", "alltoall", "allreduce", "barrier" };
   std::vector<size_t> bytes{ 1024, 16384, 65536, 262144, 1048576 };
   long repeats   = 20;
   double seconds = 0;
   long warmup    = 2;
   bool check     = true;
   bool trace     = false;
};

[[noreturn]] void fail(const std::string& message)
{
   if (rank == 0) std::fprintf(stderr, "mpi_bench: %s (see the comment at the top of mpi_bench.cpp)\n", message.c_str());
   MPI_Finalize();
   std::exit(2);
}

std::vector<std::string> split(const std::string& s)
{
   std::vector<std::string> parts;
   size_t start = 0;
   while (start <= s.size())
   {
      const size_t comma = s.find(',', start);
      const size_t end   = comma == std::string::npos ? s.size() : comma;
      if (end > start) parts.push_back(s.substr(start, end - start));
      start = end + 1;
   }
   return parts;
}

size_t parseBytes(const std::string& s)
{
   char* end         = nullptr;
   const double value = std::strtod(s.c_str(), &end);
   double unit        = 1;
   if (*end == 'K' || *end == 'k') { unit = 1024; ++end; }
   else if (*end == 'M' || *end == 'm') { unit = 1024.0 * 1024.0; ++end; }
   if (end == s.c_str() || *end != '\0' || value < 0 || value * unit > 1024.0 * 1024.0 * 1024.0)
      fail("not a message size: " + s);
   return size_t(value * unit);
}

Options parse(int argc, char** argv)
{
   Options o;
   for (int i = 1; i < argc; ++i)
   {
      const std::string a = argv[i];
      auto value          = [&]() -> std::string {
         if (i + 1 >= argc) fail(a + " needs a value");
         return argv[++i];
      };
      if (a == "--pattern") o.patterns = split(value());
      else if (a == "--bytes")
      {
         o.bytes.clear();
         for (const auto& b : split(value())) o.bytes.push_back(parseBytes(b));
      }
      else if (a == "--repeats") o.repeats = std::atol(value().c_str());
      else if (a == "--seconds") o.seconds = std::atof(value().c_str());
      else if (a == "--warmup") o.warmup = std::atol(value().c_str());
      else if (a == "--no-check") o.check = false;
      else if (a == "--trace") o.trace = true;
      else fail("unknown option " + a);
   }
   for (const auto& p : o.patterns)
      if (p != "ring" && p != "halo" && p != "alltoall" && p != "allreduce" && p != "barrier")
         fail("unknown pattern " + p);
   if (o.bytes.empty() || o.repeats < 1 || o.warmup < 0 || o.seconds < 0) fail("bad --bytes, --repeats, --warmup or --seconds");
   return o;
}

//  every message byte is the same value, from the sender and the repetition: stale or mixed-up data is seen
unsigned char stamp(int sender, long iteration) { return (unsigned char) ((sender * 31 + iteration * 7 + 1) & 0xff); }

long countWrong(const std::vector< unsigned char >& buffer, size_t offset, size_t bytes, unsigned char want)
{
   long wrong = 0;
   for (size_t i = 0; i < bytes; ++i) wrong += buffer[offset + i] != want;
   return wrong;
}

//  the halo pattern's neighbours: face and edge directions (1 <= |dx|+|dy|+|dz| <= 2) that stay inside the grid
struct Halo
{
   std::array< int, 3 > dims{ 0, 0, 0 };
   std::vector< int > peers;    // neighbour rank per direction that exists
   std::vector< int > sendTag;  // the direction index (towards the neighbour)
   std::vector< int > recvTag;  // the neighbour's direction index towards us (the opposite direction)

   Halo()
   {
      MPI_Dims_create(size, 3, dims.data());
      // row-major rank <-> coordinates, as MPI_Cart_create without reordering
      const int z = rank % dims[2], y = (rank / dims[2]) % dims[1], x = rank / (dims[1] * dims[2]);
      std::vector< std::array< int, 3 > > dirs;
      for (int dx = -1; dx <= 1; ++dx)
         for (int dy = -1; dy <= 1; ++dy)
            for (int dz = -1; dz <= 1; ++dz)
            {
               const int n = std::abs(dx) + std::abs(dy) + std::abs(dz);
               if (n >= 1 && n <= 2) dirs.push_back({ dx, dy, dz });
            }
      auto index = [&](int dx, int dy, int dz) {
         for (size_t d = 0; d < dirs.size(); ++d)
            if (dirs[d][0] == dx && dirs[d][1] == dy && dirs[d][2] == dz) return int(d);
         return -1;
      };
      for (size_t d = 0; d < dirs.size(); ++d)
      {
         const int nx = x + dirs[d][0], ny = y + dirs[d][1], nz = z + dirs[d][2];
         if (nx < 0 || ny < 0 || nz < 0 || nx >= dims[0] || ny >= dims[1] || nz >= dims[2]) continue;
         peers.push_back((nx * dims[1] + ny) * dims[2] + nz);
         sendTag.push_back(int(d));
         recvTag.push_back(index(-dirs[d][0], -dirs[d][1], -dirs[d][2]));
      }
   }
};

//  one step: <pattern> with <bytes> per message; returns {seconds per repetition (timed part), repetitions,
//  wrong bytes, number of peers}
struct StepResult
{
   double seconds;
   long repeats;
   long wrong;
   int peers;
};

StepResult runStep(const Options& o, const Halo& halo, const std::string& pattern, size_t bytes)
{
   std::vector< int > peers, sendTag, recvTag;
   if (pattern == "ring" && size > 1)
   {
      peers   = { (rank + 1) % size, (rank + size - 1) % size };  // up, down
      sendTag = { 0, 1 };  // tag 0 goes up, tag 1 goes down
      recvTag = { 1, 0 };  // so from up comes tag 1 (it sent down), from down tag 0
   }
   else if (pattern == "halo")
   {
      peers   = halo.peers;
      sendTag = halo.sendTag;
      recvTag = halo.recvTag;
   }
   const size_t nPeers = peers.size();
   std::vector< unsigned char > sendBuf, recvBuf;
   std::vector< double > reduceIn, reduceOut;
   if (pattern == "ring" || pattern == "halo") { sendBuf.resize(bytes * nPeers); recvBuf.resize(bytes * nPeers); }
   else if (pattern == "alltoall") { sendBuf.resize(bytes * size_t(size)); recvBuf.resize(bytes * size_t(size)); }
   else if (pattern == "allreduce") { reduceIn.resize(std::max< size_t >(1, bytes / 8)); reduceOut.resize(reduceIn.size()); }

   long wrong = 0;
   auto once  = [&](long it) {
      if (pattern == "ring" || pattern == "halo")
      {
         std::vector< MPI_Request > req(2 * nPeers);
         std::memset(sendBuf.data(), stamp(rank, it), sendBuf.size());
         if (o.check) std::memset(recvBuf.data(), 0, recvBuf.size());
         for (size_t p = 0; p < nPeers; ++p)
            MPI_Irecv(recvBuf.data() + p * bytes, int(bytes), MPI_BYTE, peers[p], recvTag[p], MPI_COMM_WORLD, &req[p]);
         for (size_t p = 0; p < nPeers; ++p)
            MPI_Isend(sendBuf.data() + p * bytes, int(bytes), MPI_BYTE, peers[p], sendTag[p], MPI_COMM_WORLD, &req[nPeers + p]);
         MPI_Waitall(int(req.size()), req.data(), MPI_STATUSES_IGNORE);
         if (o.check)
            for (size_t p = 0; p < nPeers; ++p) wrong += countWrong(recvBuf, p * bytes, bytes, stamp(peers[p], it));
      }
      else if (pattern == "alltoall")
      {
         std::memset(sendBuf.data(), stamp(rank, it), sendBuf.size());
         MPI_Alltoall(sendBuf.data(), int(bytes), MPI_BYTE, recvBuf.data(), int(bytes), MPI_BYTE, MPI_COMM_WORLD);
         if (o.check)
            for (int r = 0; r < size; ++r) wrong += countWrong(recvBuf, size_t(r) * bytes, bytes, stamp(r, it));
      }
      else if (pattern == "allreduce")
      {
         std::fill(reduceIn.begin(), reduceIn.end(), double(rank + it));
         MPI_Allreduce(reduceIn.data(), reduceOut.data(), int(reduceIn.size()), MPI_DOUBLE, MPI_SUM, MPI_COMM_WORLD);
         const double want = double(size) * double(size - 1) / 2 + double(size) * double(it);
         if (o.check)
            for (double v : reduceOut) wrong += v != want;
      }
      else if (pattern == "barrier") MPI_Barrier(MPI_COMM_WORLD);
   };

   long iteration = 0;
   for (; iteration < o.warmup; ++iteration) once(iteration);
   long repeats = o.repeats;
   if (o.seconds > 0)
   {
      //  calibrate: double the repetitions until they take a tenth of the target; the slowest rank's time
      //  decides (MPI_MAX), so that every rank runs the same count
      for (long n = 1;; n *= 2)
      {
         const double t0 = MPI_Wtime();
         for (long k = 0; k < n; ++k) once(iteration++);
         double t = MPI_Wtime() - t0, tMax = 0;
         MPI_Allreduce(&t, &tMax, 1, MPI_DOUBLE, MPI_MAX, MPI_COMM_WORLD);
         if (tMax >= 0.1 * o.seconds || n >= (long(1) << 24))
         {
            repeats = std::clamp< long >(long(o.seconds * double(n) / std::max(tMax, 1e-9)), 1, 100000000);
            break;
         }
      }
   }
   const double t0 = MPI_Wtime();
   for (long it = 0; it < repeats; ++it) once(iteration++);
   return { (MPI_Wtime() - t0) / double(repeats), repeats, wrong, int(pattern == "alltoall" ? size - 1 : int(nPeers)) };
}

//  the threads of this process: id, name, CPU time in seconds (from /proc/self/task/<tid>/stat, fields 14 and 15,
//  utime and stime, in clock ticks)
struct ThreadTime
{
   long tid;
   std::string name;
   double cpu;
};

std::vector< ThreadTime > readThreads()
{
   std::vector< ThreadTime > list;
   const double tick = double(sysconf(_SC_CLK_TCK));
   DIR* dir          = opendir("/proc/self/task");
   if (dir == nullptr) return list;
   while (const dirent* e = readdir(dir))
   {
      if (e->d_name[0] == '.') continue;
      const std::string base = std::string("/proc/self/task/") + e->d_name;
      std::ifstream statFile(base + "/stat"), commFile(base + "/comm");
      const std::string stat((std::istreambuf_iterator< char >(statFile)), std::istreambuf_iterator< char >());
      std::string name;
      std::getline(commFile, name);
      const size_t close = stat.rfind(')');  // the name in parentheses may contain spaces
      if (close == std::string::npos || close + 2 >= stat.size()) continue;
      std::istringstream rest(stat.substr(close + 2));
      std::string field;
      double ticks = 0;
      for (int f = 3; f <= 15 && (rest >> field); ++f)
         if (f == 14 || f == 15) ticks += std::atof(field.c_str());
      list.push_back({ std::atol(e->d_name), name, ticks / tick });
   }
   closedir(dir);
   std::sort(list.begin(), list.end(), [](const ThreadTime& x, const ThreadTime& y) { return x.tid < y.tid; });
   return list;
}

//  each thread's CPU time since <start> (the list read then) as a share of <wall> seconds; also the thread count
//  and the busiest non-main thread
std::string threadReport(const std::vector< ThreadTime >& start, double wall, int& threads, double& busiestHelper)
{
   const long self = long(getpid());
   std::string out;
   threads       = 0;
   busiestHelper = 0;
   for (const ThreadTime& t : readThreads())
   {
      double before = 0;
      for (const ThreadTime& s : start)
         if (s.tid == t.tid) before = s.cpu;
      const double share = wall > 0 ? 100.0 * (t.cpu - before) / wall : 0;
      const bool isMain  = t.tid == self;
      ++threads;
      if (!isMain) busiestHelper = std::max(busiestHelper, share);
      char item[128];
      std::snprintf(item, sizeof(item), "%s%s %.0f%%", t.name.c_str(), isMain ? "(main)" : "", share);
      out += (out.empty() ? "" : ", ") + std::string(item);
   }
   return out;
}

}  // namespace

int main(int argc, char** argv)
{
   MPI_Init(&argc, &argv);
   MPI_Comm_rank(MPI_COMM_WORLD, &rank);
   MPI_Comm_size(MPI_COMM_WORLD, &size);
   const double tStart                    = MPI_Wtime();
   const std::vector< ThreadTime > tStartThreads = readThreads();
   const Options o     = parse(argc, argv);
   const Halo halo;
   int threads          = 0;
   double busiestHelper = 0;

   //  header: where the ranks run and what is tested
   int cpu = sched_getcpu();
   std::vector< int > cpus(static_cast< size_t >(size));
   MPI_Gather(&cpu, 1, MPI_INT, cpus.data(), 1, MPI_INT, 0, MPI_COMM_WORLD);
   if (rank == 0)
   {
      std::string list, pats, sizes;
      for (int i = 0; i < size; ++i) list += (i ? "," : "") + std::to_string(cpus[size_t(i)]);
      for (const auto& p : o.patterns) pats += (pats.empty() ? "" : ",") + p;
      for (size_t b : o.bytes) sizes += (sizes.empty() ? "" : ",") + std::to_string(b);
      std::printf("mpi_bench start np=%d grid=%dx%dx%d patterns=%s bytes=%s %s warmup=%ld check=%s cores=%s\n", size,
                  halo.dims[0], halo.dims[1], halo.dims[2], pats.c_str(), sizes.c_str(),
                  o.seconds > 0 ? ("seconds=" + std::to_string(o.seconds)).c_str() : ("repeats=" + std::to_string(o.repeats)).c_str(),
                  o.warmup, o.check ? "on" : "off", list.c_str());
      std::fflush(stdout);
   }

   long totalWrong = 0;
   int steps       = 0;
   for (const auto& pattern : o.patterns)
   {
      const std::vector< size_t > sizes = pattern == "barrier" ? std::vector< size_t >{ 0 } : o.bytes;
      for (size_t bytes : sizes)
      {
         if ((pattern == "ring" && size < 2) || (pattern == "alltoall" && bytes * size_t(size) > (size_t(64) << 20)))
         {
            if (rank == 0) std::printf("mpi_bench pattern=%s np=%d bytes=%zu skipped\n", pattern.c_str(), size, bytes);
            continue;
         }
         if (o.trace) { std::printf("trace rank=%d %s bytes=%zu enter\n", rank, pattern.c_str(), bytes); std::fflush(stdout); }
         const StepResult r = runStep(o, halo, pattern, bytes);
         if (o.trace) { std::printf("trace rank=%d %s bytes=%zu leave\n", rank, pattern.c_str(), bytes); std::fflush(stdout); }
         //  the slowest rank's time, the fewest and most peers, and all wrong bytes
         std::array< double, 3 > mine{ r.seconds, -double(r.peers), double(r.peers) }, most{};
         MPI_Allreduce(mine.data(), most.data(), 3, MPI_DOUBLE, MPI_MAX, MPI_COMM_WORLD);
         long wrong = 0;
         MPI_Allreduce(&r.wrong, &wrong, 1, MPI_LONG, MPI_SUM, MPI_COMM_WORLD);
         totalWrong += wrong;
         ++steps;
         if (rank == 0)
         {
            std::printf("mpi_bench pattern=%s np=%d bytes=%zu repeats=%ld peers=%d..%d us_per_repeat=%.1f errors=%ld\n",
                        pattern.c_str(), size, bytes, r.repeats, int(-most[1]), int(most[2]), most[0] * 1e6, wrong);
            std::fflush(stdout);
         }
      }
   }
   //  rank 0's threads, and over all ranks the most threads in one process and the busiest helper thread
   const double wall        = MPI_Wtime() - tStart;
   const std::string report = threadReport(tStartThreads, wall, threads, busiestHelper);
   double mine[2] = { double(threads), busiestHelper }, most[2] = { 0, 0 };
   MPI_Allreduce(mine, most, 2, MPI_DOUBLE, MPI_MAX, MPI_COMM_WORLD);
   if (rank == 0)
   {
      std::printf("mpi_bench threads rank=0 wall=%.1fs cpu: %s\n", wall, report.c_str());
      std::printf("mpi_bench threads all-ranks: up to %d threads per process, busiest helper thread %.0f%% of the run\n",
                  int(most[0]), most[1]);
      std::printf("mpi_bench done np=%d steps=%d errors=%ld\n", size, steps, totalWrong);
      std::fflush(stdout);
   }
   MPI_Finalize();
   return totalWrong == 0 ? 0 : 1;
}
