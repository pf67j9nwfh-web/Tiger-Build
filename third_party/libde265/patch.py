#!/usr/bin/env python3
"""Makes libde265's decoder build with gcc 4.0 and 4.2 (C++98 plus tr1) on the old Macs.
usage: patch.py SOURCE_DIR VERSION"""
import glob, os, re, sys
d, version = sys.argv[1], sys.argv[2]
major, minor, patch = (int(x) for x in version.split('.'))

def edit(name, fn):
    p = os.path.join(d, name)
    s = open(p).read()
    t = fn(s)
    open(p, 'w').write(t)

# the version header is a template
edit('de265-version.h', lambda s: s.replace('@NUMERIC_VERSION@', '0x%02x%02x%02x00' % (major, minor, patch)).replace('@PACKAGE_VERSION@', version))

# std::shared_ptr, make_shared, <memory>: tr1 has them
for path in glob.glob(os.path.join(d, '*.h')) + glob.glob(os.path.join(d, '*.cc')):
    name = os.path.basename(path)
    if name in ('en265.cc', 'en265.h', 'visualize.cc', 'visualize.h', 'image-io.cc', 'image-io.h', 'quality.cc', 'quality.h'):
        continue
    s = open(path).read()
    t = s.replace('#include <memory>', '#include <tr1/memory>').replace('std::shared_ptr', 'std::tr1::shared_ptr')
    t = re.sub(r'std::make_shared<(\w+)>\(\)', r'std::tr1::shared_ptr<\1>(new \1())', t)
    if t != s:
        open(path, 'w').write(t)

# <atomic> is included but not used
edit('threads.h', lambda s: s.replace('#include <atomic>\n', ''))

# the one-time initialisation lock: a pthread mutex
def init_lock(s):
    s = s.replace('#include <mutex>', '#include <pthread.h>')
    s = s.replace('''static std::mutex& de265_init_mutex()
{
  static std::mutex de265_init_mutex;
  return de265_init_mutex;
}''', '''static pthread_mutex_t de265_init_mutex = PTHREAD_MUTEX_INITIALIZER;

struct de265_init_lock {
  de265_init_lock() { pthread_mutex_lock(&de265_init_mutex); }
  ~de265_init_lock() { pthread_mutex_unlock(&de265_init_mutex); }
};''')
    return s.replace('std::lock_guard<std::mutex> lock(de265_init_mutex());', 'de265_init_lock lock;')
edit('de265.cc', init_lock)

# range-based for
edit('decctx.cc', lambda s: s.replace('''  for (auto& p : pps) {
    if (p && p->seq_parameter_set_id == new_sps->seq_parameter_set_id) {
      p = nullptr;
    }
  }''', '''  for (int i = 0; i < DE265_MAX_PPS_SETS; i++) {
    if (pps[i] && pps[i]->seq_parameter_set_id == new_sps->seq_parameter_set_id) {
      pps[i].reset();
    }
  }'''))

# nullptr, and a comparison or assignment of a shared_ptr with it
edit('decctx.cc', lambda s: re.sub(r'current_(vps|sps|pps)\s*=\s*nullptr;', r'current_\1.reset();', s.replace('pps[pps_id]==nullptr', '!pps[pps_id]')))
for path in glob.glob(os.path.join(d, '*.cc')) + glob.glob(os.path.join(d, '*.h')):
    s = open(path).read()
    if 'nullptr' in s:
        s = re.sub(r'(current_(?:vps|sps|pps))\s*=\s*nullptr;', r'\1.reset();', s)
        open(path, 'w').write(re.sub(r'\bnullptr\b', 'NULL', s))

# range-based for loops written with the FOR_LOOP macro, which older compilers cannot do
def pool(s):
    s = s.replace("FOR_LOOP(uint8_t*, p, m_memBlocks) {\n    delete[] p;", "for (size_t b = 0; b < m_memBlocks.size(); b++) {\n    delete[] m_memBlocks[b];")
    return s.replace("FOR_LOOP(uint8_t*, memBlk, m_memBlocks) {\n    if", "for (size_t b = 0; b < m_memBlocks.size(); b++) {\n    uint8_t* memBlk = m_memBlocks[b];\n    if")
edit('alloc_pool.cc', pool)
edit('alloc_pool.h', lambda s: s.replace('#include <cstdint>', '#include <stdint.h>').replace('#include <cstddef>', '#include <stddef.h>'))

# a shared_ptr is emptied with reset()
edit('decctx.cc', lambda s: re.sub(r'(current_(?:vps|sps|pps))\s*=\s*NULL;', r'\1.reset();', s))
edit('pps.cc', lambda s: re.sub(r'\bsps\s*=\s*NULL;', 'sps.reset();', s))

# any other shared_ptr set to null
for path in glob.glob(os.path.join(d, '*.cc')):
    s = open(path).read()
    t = re.sub(r'\b((?:current_)?(?:vps|sps|pps))\s*=\s*NULL;', r'\1.reset();', s)
    t = re.sub(r'\b((?:vps|sps|pps)\[[^\]]+\])\s*=\s*NULL;', r'\1.reset();', t)
    if t != s:
        open(path, 'w').write(t)
