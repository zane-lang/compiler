# Instructions per function (the kept build with light scopes)

Flagged: Zane over 1.10× the better of Goose and C in a function that takes at least 5% of Zane's total, against a language only where its whole program runs fewer instructions than Zane's, in programs of 10 M instructions or more.

## Flagged

- trialdiv: main
- fannkuch: main
- entities: main
- listgrowth: main
- ntree: grow

### startup (no argument)

| function | zane | goose | c | Zane ÷ best |
| --- | --- | --- | --- | --- |
| total | 0.4 M | 0.4 M | 0.2 M | 1.56 |
| gitunablesinit | 0.1 M | 60 K | 60 K | 1.84 |
| dolookupx | 40 K | 70 K | 44 K | 0.92 |
| vfscanfinternal | 47 K | 48 K | — | — |
| dlrelocateobjectnorelro | — | 47 K | 36 K | — |
| dllookupsymbolx | 13 K | 36 K | 23 K | 0.57 |
| strtoullinternal | 23 K | 24 K | — | — |
| strcmp | 11 K | 18 K | 11 K | 0.95 |
| dlrelocateobject | 17 K | 0 K | 0 K | 237.27 |
| checkmatch | 8 K | 14 K | 8 K | 1.00 |
| dlcheckmapversions | 6 K | 9 K | 7 K | 0.75 |
| dlmapnewobject | — | 6 K | 6 K | — |
| intelcheckword.constprop.0 | 3 K | 6 K | 6 K | — |
| main | 5 K | 0 K | 0 K | 662.62 |
| iosputbackc | 4 K | 5 K | — | — |
| getdelim | 3 K | 4 K | — | — |

### primes (no argument)

| function | zane | goose | c | Zane ÷ best |
| --- | --- | --- | --- | --- |
| total | 0.4 M | 0.8 M | 0.6 M | 0.66 |
| main | 5 K | 0.3 M | 0.3 M | — |
| gitunablesinit | 0.1 M | 60 K | 60 K | — |
| dolookupx | 40 K | 70 K | 44 K | — |
| vfscanfinternal | 47 K | 48 K | — | — |
| dlrelocateobjectnorelro | — | 47 K | 36 K | — |
| memsetavx2unalignederms | 0 K | 40 K | — | — |
| dllookupsymbolx | 13 K | 36 K | 23 K | — |
| strtoullinternal | 23 K | 24 K | — | — |
| strcmp | 11 K | 18 K | 11 K | — |
| dlrelocateobject | 17 K | 0 K | 0 K | — |
| checkmatch | 8 K | 14 K | 8 K | — |
| dlcheckmapversions | 6 K | 9 K | 7 K | — |
| dlmapnewobject | — | 6 K | 6 K | — |
| intelcheckword.constprop.0 | 3 K | 6 K | 6 K | — |
| iosputbackc | 4 K | 5 K | — | — |
| getdelim | 3 K | 4 K | — | — |

### trialdiv (1000000)

| function | zane | goose | c | Zane ÷ best |
| --- | --- | --- | --- | --- |
| total | 300.6 M | 301.5 M | 242.8 M | 1.24 |
| **main** | 300.2 M | 301.1 M | 242.5 M | 1.24 |

### binarytrees (14)

| function | zane | goose | c | Zane ÷ best |
| --- | --- | --- | --- | --- |
| total | 90.6 M | 141.9 M | 1169.5 M | 0.64 |
| intmalloc | 2 K | 1 K | 332.3 M | — |
| intfreemergechunk | — | 0 K | 164.4 M | — |
| intfreecreatechunk | — | 0 K | 134.7 M | — |
| free | 0 K | 0 K | 115.2 M | — |
| make | 61.6 M | 83.9 M | 90.1 M | — |
| malloc | 0 K | 0 K | 76.6 M | — |
| libcmalloc2 | — | 0 K | 68.8 M | — |
| unlinkchunk.isra.0 | — | 0 K | 67.1 M | — |
| check | 25.4 M | 57.3 M | 38.0 M | — |
| release | — | — | 49.9 M | — |
| intfreechunk | — | — | 28.7 M | — |
| intfreemaybetrim.part.0 | — | — | 3.1 M | — |
| main | 1.8 M | 0.3 M | 0.2 M | — |
| zaneallocheld | 1.4 M | — | — | — |

### mandelbrot (400)

| function | zane | goose | c | Zane ÷ best |
| --- | --- | --- | --- | --- |
| total | 66.2 M | 66.1 M | 78.9 M | 1.00 |
| main | 65.5 M | 65.7 M | 78.6 M | 1.00 |

### fannkuch (9)

| function | zane | goose | c | Zane ÷ best |
| --- | --- | --- | --- | --- |
| total | 169.3 M | 105.6 M | 103.7 M | 1.63 |
| **main** | 168.9 M | 105.2 M | 90.3 M | 1.87 |
| memcpyavxunalignederms | 1 K | 1 K | 13.1 M | — |

### entities (300000)

| function | zane | goose | c | Zane ÷ best |
| --- | --- | --- | --- | --- |
| total | 80.2 M | 64.2 M | 64.0 M | 1.25 |
| **main** | 79.8 M | 63.8 M | 63.8 M | 1.25 |

### listgrowth (500000)

| function | zane | goose | c | Zane ÷ best |
| --- | --- | --- | --- | --- |
| total | 160.4 M | 125.4 M | 216.8 M | 1.28 |
| **main** | 160.0 M | 125.0 M | 190.0 M | 1.28 |
| memcpyavxunalignederms | 1 K | 1 K | 26.4 M | — |

### ntree (8)

| function | zane | goose | c | Zane ÷ best |
| --- | --- | --- | --- | --- |
| total | 89.9 M | 48.6 M | 478.4 M | 1.85 |
| intmalloc | 2 K | 1 K | 123.8 M | — |
| intfreemergechunk | — | 0 K | 64.2 M | — |
| libccalloc2 | — | 0 K | 55.9 M | — |
| **grow** | 52.7 M | 20.9 M | 24.7 M | 2.52 |
| intfreecreatechunk | — | 0 K | 50.5 M | — |
| free | 0 K | 0 K | 46.8 M | — |
| count | 23.8 M | 27.3 M | 21.8 M | 0.87 |
| unlinkchunk.isra.0 | — | 0 K | 25.3 M | — |
| calloc | 0 K | 0 K | 23.6 M | — |
| release | — | — | 20.5 M | — |
| intfreechunk | — | — | 10.9 M | — |
| zanelistfirst | 8.1 M | — | — | — |
| libcmalloc2 | — | 0 K | 5.2 M | — |
| malloc | 0 K | 0 K | 4.8 M | — |
| zanelistpush | 3.7 M | — | — | — |
| zaneregionat | 0.9 M | — | — | — |

### treecopy (14)

| function | zane | goose | c | Zane ÷ best |
| --- | --- | --- | --- | --- |
| total | 23.3 M | 53.2 M | 266.9 M | 0.44 |
| intmalloc | 2 K | 1 K | 78.0 M | — |
| intfreemergechunk | — | 0 K | 39.5 M | — |
| copytree | — | 38.7 M | — | — |
| intfreecreatechunk | — | 0 K | 32.4 M | — |
| free | 0 K | 0 K | 24.1 M | — |
| copy | — | — | 18.3 M | — |
| libcmalloc2 | — | 0 K | 16.5 M | — |
| unlinkchunk.isra.0 | — | 0 K | 15.9 M | — |
| malloc | 0 K | 0 K | 15.1 M | — |
| branch.copy | 14.1 M | — | — | — |
| sum | 7.7 M | 13.1 M | 8.1 M | — |
| release | — | — | 10.7 M | — |
| intfreechunk | — | — | 6.9 M | — |
| make | 1.0 M | 1.0 M | 1.0 M | — |

### nbody (200000)

| function | zane | goose | c | Zane ÷ best |
| --- | --- | --- | --- | --- |
| total | 120.8 M | 116.6 M | 117.4 M | 1.04 |
| main | 120.4 M | 116.2 M | 117.2 M | 1.04 |

### spectralnorm (300)

| function | zane | goose | c | Zane ÷ best |
| --- | --- | --- | --- | --- |
| total | 65.4 M | 70.7 M | 70.5 M | 0.93 |
| main | 6 K | 70.3 M | 70.3 M | — |
| timestransposed | 34.3 M | — | — | — |
| times | 30.7 M | — | — | — |

### allocfree (200000)

| function | zane | goose | c | Zane ÷ best |
| --- | --- | --- | --- | --- |
| total | 108.4 M | 152.4 M | 746.5 M | 0.71 |
| intmalloc | 2 K | 1 K | 226.8 M | — |
| main | 108.0 M | 152.0 M | 92.0 M | — |
| intfreemergechunk | — | 0 K | 105.0 M | — |
| intfreecreatechunk | — | 0 K | 93.6 M | — |
| free | 0 K | 0 K | 70.0 M | — |
| libcmalloc2 | — | 0 K | 48.0 M | — |
| unlinkchunk.isra.0 | — | 0 K | 46.5 M | — |
| malloc | 0 K | 0 K | 44.0 M | — |
| intfreechunk | — | — | 20.0 M | — |

### particles (5000)

| function | zane | goose | c | Zane ÷ best |
| --- | --- | --- | --- | --- |
| total | 136.0 M | 142.9 M | 173.3 M | 0.95 |
| main | 135.6 M | 142.5 M | 117.0 M | — |
| intfreemergechunk | — | 0 K | 11.7 M | — |
| free | 0 K | 0 K | 11.0 M | — |
| malloc | 0 K | 0 K | 10.8 M | — |
| intfreecreatechunk | — | 0 K | 9.9 M | — |
| intmalloc | 2 K | 1 K | 9.0 M | — |
| intfreechunk | — | — | 2.3 M | — |

### concscan (300000)

| function | zane | goose | c | Zane ÷ best |
| --- | --- | --- | --- | --- |
| total | 0.0 M | 275.0 M | 66.6 M | — |
| memcpyavxunalignederms | — | 205.3 M | 10 K | — |
| gstmainshardsum | — | 60.0 M | — | — |
| shardsum | — | — | 60.0 M | — |
| main | — | 5.4 M | 5.4 M | — |
| intmalloc | — | 0.8 M | 1 K | — |
| mallocarenathreadfreeres | — | 0.3 M | 11 K | — |
| free | — | 0.3 M | 88 K | — |
| intfreemergechunk | — | 0.2 M | — | — |
| pthreadcreate | — | 0.2 M | 0.2 M | — |
| intfreemaybetrim.part.0 | — | 0.2 M | — | — |
| libccalloc2 | — | 0.1 M | 0 K | — |
| intfreecreatechunk | — | 0.1 M | — | — |
| libcmalloc2 | — | 0.1 M | 0 K | — |
| intfreechunk | — | 0.1 M | 0 K | — |
| unlinkchunk.isra.0 | — | 0.1 M | — | — |
| pthreadmutexlock | — | 88 K | 16 K | — |
| printfbuffer | — | 86 K | 87 K | — |
| dolookupx | — | 70 K | 45 K | — |
| startthread | — | 68 K | 67 K | — |
| pthreadmutexunlockusercnt | — | 67 K | 13 K | — |
| dlallocatetlsinit | — | 66 K | 45 K | — |
| gitunablesinit | — | 60 K | 60 K | — |
| memsetavx2unalignederms | — | 55 K | 10 K | — |
| malloc | — | 51 K | 0 K | — |
| vfscanfinternal | — | 48 K | — | — |
| dlrelocateobjectnorelro | — | 47 K | 37 K | — |
| printfbufferwrite | — | 43 K | 43 K | — |
| pthreadgetattrnp | — | 43 K | — | — |
| calloc | — | 42 K | 0 K | — |
| gsthreadstart | — | 41 K | — | — |
| dllookupsymbolx | — | 36 K | 24 K | — |
| itoaword | — | 34 K | 34 K | — |
| gsthreadmain | — | 34 K | — | — |
| gsnativestackinit | — | 33 K | — | — |
| createthread | — | 26 K | 26 K | — |
| gsthreadwait | — | 26 K | — | — |
| strtoullinternal | — | 24 K | — | — |
| gsqput | — | 22 K | — | — |
| setvmaname | — | 22 K | 22 K | — |
| memset | — | 22 K | 11 K | — |
| nptldeallocatestack | — | 21 K | 21 K | — |
| gsreleaseregions | — | 21 K | — | — |
| tcacheinit.part.0 | — | 20 K | — | — |
| pthreadattrsetaffinitynp | — | 19 K | — | — |
| cloneinternal | — | 18 K | 18 K | — |
| arenaget2 | — | 18 K | — | — |
| pthreadclockjoinex | — | — | 18 K | — |
| strcmp | — | 18 K | 12 K | — |
| pthreadcondbroadcast | — | 17 K | — | — |
| pthreadcondwait | — | 16 K | — | — |
| getpagesize | — | 16 K | 8 K | — |
| pthreadattrcopy | — | — | 16 K | — |
| strchrnulavx2 | — | 15 K | 15 K | — |
| pthreadattrinit | — | 15 K | — | — |
| vsnprintfinternal | — | 15 K | 15 K | — |
| isdecoratemapsenabled | — | 15 K | 14 K | — |
| mempcpy | — | 14 K | 9 K | — |
| checkmatch | — | 14 K | 8 K | — |
| gsqget | — | 13 K | — | — |
| snprintf | — | 13 K | 13 K | — |
| pthreadcondsignal | — | 12 K | — | — |
| pthreadgetaffinitynp | — | 11 K | — | — |
| pthreadattrdestroy | — | 10 K | 3 K | — |
| llllockwake | — | 10 K | — | — |
| sigsetjmp | — | 10 K | 10 K | — |
| pthreadgetattrdefaultnp | — | — | 10 K | — |
| futexabstimedwaitcancelable64 | — | 10 K | 5 K | — |
| llllockwait | — | 9 K | — | — |
| dlcheckmapversions | — | 9 K | 7 K | — |
| ctypeinit | — | 9 K | 9 K | — |
| printfbufferdone | — | 8 K | 8 K | — |
| gsthreadrelease | — | 8 K | — | — |
| pthreadattrextension | — | 8 K | — | — |
| clone | — | 8 K | 8 K | — |
| sigaltstack | — | 7 K | — | — |
| pthreadmutexunlock | — | 7 K | 1 K | — |
| calltlsdtors | — | 7 K | 7 K | — |
| tcachefreeinit | — | 6 K | — | — |
| resolvcontextfreeres | — | 6 K | 6 K | — |
| nptlstacklistadd | — | 6 K | 6 K | — |
| dlmapnewobject | — | 6 K | 6 K | — |
| intelcheckword.constprop.0 | — | 6 K | 6 K | — |
| resthreadfreeres | — | 6 K | 6 K | — |
| rpcthreaddestroy | — | 6 K | 6 K | — |
| pthreadattrgetstack | — | 5 K | — | — |
| nptlstacklistdel | — | 5 K | 5 K | — |
| iosputbackc | — | 5 K | — | — |
| glibctlsinternalfree | — | 5 K | 5 K | — |
| pthreadmutexcondlock | — | 5 K | — | — |
| clone3internal | — | 4 K | 4 K | — |
| pthreadtestcancel | — | — | 4 K | — |
| getdelim | — | 4 K | — | — |
| realloc | — | 4 K | — | — |
| sigjmpsave | — | 4 K | 4 K | — |
| libcthreadfreeres | — | 4 K | 4 K | — |
| getrandomvdsorelease | — | 4 K | 4 K | — |
| nptlfreetcb | — | 4 K | 4 K | — |
| pthreadattrsetdetachstate | — | 3 K | — | — |
| libcdlerrorresultfree | — | 3 K | 3 K | — |
| nptldeallocatetsd | — | 3 K | 3 K | — |
| strsep | — | 3 K | 3 K | — |
| gsthreadrun | — | 3 K | — | — |
| isoc23sscanf | — | 3 K | — | — |
| madvise | — | 2 K | 2 K | — |
| syscallcancelarch | — | 2 K | 1 K | — |
| memchravx2 | — | 2 K | — | — |
| condvarconfirmwakeup | — | 2 K | — | — |
| decomposerpath | — | 2 K | 2 K | — |
| pthreadjoin | — | — | 2 K | — |
| dlmapobjectdeps | — | 2 K | 2 K | — |
| iostrinitstaticinternal | — | 2 K | — | — |
| dlmain | — | 2 K | 2 K | — |
| dlnamematchp | — | 2 K | 2 K | — |
| pthreadcleanuppush | — | 2 K | — | — |
| pthreadcleanuppop | — | 2 K | — | — |
| strlenavx2 | — | 1 K | — | — |
| ionoinit | — | 1 K | — | — |
| iooldinit | — | 1 K | — | — |
| ioenablelocks | — | 1 K | 1 K | — |
| openpath | — | 1 K | 1 K | — |
| iosetb | — | 1 K | 0 K | — |
| setjmp | — | 1 K | 1 K | — |
| pthreadself | — | 1 K | — | — |
| minimalmalloc | — | 1 K | 1 K | — |
| mmap | — | 1 K | 1 K | — |
| dlnextldenventry | — | 1 K | 1 K | — |
| strlen | — | 1 K | 1 K | — |
| dlnewobject | — | 1 K | 1 K | — |
| dllookupmap | — | 1 K | 1 K | — |
| index | — | 1 K | 1 K | — |
| libccleanuppushdefer | — | 1 K | 0 K | — |
| tunablegetval | — | 1 K | 1 K | — |
| dlsysdepparsearguments | — | 1 K | 1 K | — |
| dlfindobjectfrommap | — | 1 K | 1 K | — |
| sysmalloc | — | 1 K | 0 K | — |
| ptmallocinit | — | 1 K | 1 K | — |
| libccleanuppoprestore | — | 1 K | 0 K | — |
| openverify.constprop.0 | — | 1 K | 1 K | — |
| memcpy | — | 1 K | 1 K | — |
| fillinrpath | — | 1 K | 1 K | — |
| dlstart | — | 1 K | 1 K | — |
| handleintel.constprop.0 | — | 1 K | 1 K | — |
| dfstraversal.part.0 | — | 0 K | 0 K | — |
| initcpufeatures.constprop.0 | — | 0 K | 0 K | — |
| strtoulinternal | — | 0 K | — | — |
| opennocancel | — | 0 K | 0 K | — |
| dlsortmaps | — | 0 K | 0 K | — |
| dlhwcapssplit | — | 0 K | 0 K | — |
| dlprocessptgnuproperty | — | 0 K | 0 K | — |
| callinit | — | 0 K | 0 K | — |
| dlcatchexception | — | 0 K | 0 K | — |
| iofileunderflow | — | 0 K | — | — |
| allocnewheap | — | 0 K | — | — |
| dlfoprocessinitial | — | 0 K | 0 K | — |
| gsreserveregion | — | 0 K | — | — |
| dlfini | — | 0 K | 0 K | — |
| dlhwcapssplitmasked | — | 0 K | 0 K | — |
| dlmapobject | — | 0 K | 0 K | — |
| strcspn | — | 0 K | 0 K | — |
| getcommoncacheinfo.constprop.0 | — | 0 K | 0 K | — |
| dlinitpaths | — | 0 K | 0 K | — |
| cxafinalize | — | 0 K | 0 K | — |
| dotunableupdateval.part.0 | — | 0 K | 0 K | — |
| dlfosortmappings | — | 0 K | 0 K | — |
| libcsigaction | — | 0 K | 0 K | — |
| dlimportanthwcaps | — | 0 K | 0 K | — |
| ioflushall | — | 0 K | 0 K | — |
| iocleanup | — | 0 K | 0 K | — |
| dlprotectrelro | — | 0 K | 0 K | — |
| updateactive.constprop.0 | — | 0 K | 0 K | — |
| dldstcount | — | 0 K | 0 K | — |
| openaux | — | 0 K | 0 K | — |
| strtollinternal | — | — | 0 K | — |
| dladdtonamespacelist | — | 0 K | 0 K | — |
| dlsetuphash | — | 0 K | 0 K | — |
| underflow | — | 0 K | — | — |
| dllookupdirect | — | 0 K | 0 K | — |
| gsfmti64 | — | 0 K | — | — |
| dlcallfini | — | 0 K | 0 K | — |
| sbrk | — | 0 K | 0 K | — |
| getline | — | 0 K | — | — |
| lookupmallocsymbol | — | 0 K | 0 K | — |
| dldeterminetlsoffset | — | 0 K | 0 K | — |
| dldeallocatetls | — | 0 K | — | — |
| expanddst.constprop.0 | — | 0 K | 0 K | — |
| dlmapsegmentalign | — | 0 K | 0 K | — |
| ioswitchtogetmode | — | 0 K | — | — |
| fstatat | — | 0 K | 0 K | — |
| iodefaultxsputn | — | — | 0 K | — |
| strdup | — | 0 K | 0 K | — |
| allocatedtv | — | 0 K | 0 K | — |
| minimalcalloc | — | 0 K | 0 K | — |
| dlnotifynewobject | — | 0 K | 0 K | — |
| rtldmallocinitreal | — | 0 K | 0 K | — |
| iofilefopen | — | 0 K | — | — |
| readnocancel | — | 0 K | 0 K | — |
| bcmp | — | 0 K | 0 K | — |
| dlallocatetls | — | 0 K | 0 K | — |
| libcscratchbuffersetarraysize | — | 0 K | 0 K | — |
| dlinitstatictls | — | 0 K | 0 K | — |
| expanddynamicstringtoken | — | 0 K | 0 K | — |
| copyhwcaps | — | 0 K | 0 K | — |
| iofileclosemaybeunlink | — | 0 K | — | — |
| gsrtstart4d3da949e563 | — | 0 K | — | — |
| iolinkin | — | 0 K | — | — |
| dlinit | — | 0 K | 0 K | — |
| unregisteratfork | — | 0 K | 0 K | — |
| vfprintfinternal | — | — | 0 K | — |
| brk | — | 0 K | 0 K | — |
| fwrite | — | 0 K | — | — |
| runexithandlers | — | 0 K | 0 K | — |
| dlcheckallversions | — | 0 K | 0 K | — |
| mprotect | — | 0 K | 0 K | — |
| getcommonindices.constprop.0 | — | 0 K | 0 K | — |
| giiounlink.part.0 | — | 0 K | — | — |
| glibcmorecore | — | 0 K | 0 K | — |
| gsosarg | — | 0 K | — | — |
| fclose | — | 0 K | — | — |
| iofileoverflow | — | 0 K | 0 K | — |
| intrealloc | — | 0 K | — | — |
| libcstartmain | — | 0 K | 0 K | — |
| dladdtoslotinfo | — | 0 K | 0 K | — |
| tlsinittp | — | 0 K | 0 K | — |
| dlrelocateobject | — | 0 K | 0 K | — |
| iofiledoallocate | — | 0 K | 0 K | — |
| minimalfree | — | 0 K | 0 K | — |
| setvbuf | — | 0 K | — | — |
| dlauditobjclose | — | 0 K | 0 K | — |
| sysmallocmmap | — | 0 K | 0 K | — |
| iofilexsputn | — | 0 K | 0 K | — |
| newheap | — | 0 K | — | — |
| handlepreloadlist | — | 0 K | 0 K | — |
| libcearlyinit | — | 0 K | 0 K | — |
| strncmp | — | 0 K | 0 K | — |
| iofileseekoff | — | 0 K | — | — |
| nptlfreestacks | — | 0 K | — | — |
| newdowrite | — | 0 K | 0 K | — |
| gsqinit | — | 0 K | — | — |
| strnlen | — | 0 K | 0 K | — |
| iodefaultsetbuf | — | 0 K | 0 K | — |
| wcschr | — | 0 K | 0 K | — |
| rindex | — | 0 K | 0 K | — |
| fopeninternal | — | 0 K | — | — |
| fstat | — | 0 K | 0 K | — |
| rtldmutexinit | — | 0 K | 0 K | — |
| memmove | — | 0 K | 0 K | — |
| memcpychk | — | 0 K | 0 K | — |
| dlhwcapscontains | — | 0 K | 0 K | — |
| gitunablesetval | — | 0 K | 0 K | — |
| memchr | — | 0 K | 0 K | — |
| wmemchr | — | 0 K | 0 K | — |
| stat | — | 0 K | 0 K | — |
| dlauditobjopen | — | 0 K | 0 K | — |
| cacherpath | — | 0 K | 0 K | — |
| iofileopen | — | 0 K | — | — |
| dlsysdepstart | — | 0 K | 0 K | — |
| inittls | — | 0 K | 0 K | — |
| dlfindobjectinit | — | 0 K | 0 K | — |
| dldebugupdate | — | 0 K | 0 K | — |
| internalatexit | — | 0 K | 0 K | — |
| write | — | 0 K | 0 K | — |
| iofilewrite | — | 0 K | 0 K | — |
| dlallocatetlsstorage | — | 0 K | 0 K | — |
| dltlsstaticsurplusinit | — | 0 K | 0 K | — |
| wmemset | — | 0 K | 0 K | — |
| dltlsinitialmodidlimitsetup | — | 0 K | 0 K | — |
| pthreadmutexinit | — | 0 K | — | — |
| dldebugpostrelocate | — | 0 K | 0 K | — |
|  | — | 0 K | 0 K | — |
| newexitfn | — | 0 K | 0 K | — |
| sigaction | — | 0 K | — | — |
| gistrstr | — | 0 K | — | — |
| dopreload | — | 0 K | 0 K | — |
| giclosenocancel | — | 0 K | 0 K | — |
| rtldmutexdummy | — | 0 K | 0 K | — |
| munmap | — | 0 K | 0 K | — |
| printf | — | — | 0 K | — |
| dlcatcherror | — | 0 K | 0 K | — |
| dlhwcapssubdirsactive | — | 0 K | 0 K | — |
| dlauditactivitynsid | — | 0 K | 0 K | — |
| getrlimit | — | 0 K | 0 K | — |
| x86cacheinfo | — | 0 K | 0 K | — |
| printfbufferflushtofile | — | — | 0 K | — |
| dlcetcheck | — | 0 K | 0 K | — |
| initmisc | — | 0 K | 0 K | — |
| munmapchunk | — | 0 K | 0 K | — |
| iofileread | — | 0 K | — | — |
| iodoallocbuf | — | 0 K | 0 K | — |
| pthreadtunablesinit | — | 0 K | 0 K | — |
| printfbuffertofileswitch | — | — | 0 K | — |
| dlcalllibcearlyinit | — | 0 K | 0 K | — |
| dldebuginitialize | — | 0 K | 0 K | — |
| wcscmp | — | 0 K | 0 K | — |
| strchrnul | — | 0 K | 0 K | — |
| wmemcmp | — | 0 K | 0 K | — |
| memsetchk | — | 0 K | 0 K | — |
| memrchr | — | 0 K | 0 K | — |
| mapdoit | — | 0 K | 0 K | — |
| dlcheckldsocacheneedsloading | — | 0 K | 0 K | — |
| iofilesync | — | 0 K | 0 K | — |
| iodowrite | — | 0 K | 0 K | — |
| mempcpychk | — | 0 K | 0 K | — |
| memmovechk | — | 0 K | 0 K | — |
| strcasecmp | — | 0 K | 0 K | — |
| iostdfilesinit | — | 0 K | 0 K | — |
| strncasecmpl | — | 0 K | 0 K | — |
| strcasecmpl | — | 0 K | 0 K | — |
| dlreceiveerror | — | 0 K | 0 K | — |
| strncasecmp | — | 0 K | 0 K | — |
| getrandomearlyinit | — | 0 K | 0 K | — |
| dlassigntlsmodid | — | 0 K | 0 K | — |
| isattynostatus | — | — | 0 K | — |
| dlloadcachetunables | — | 0 K | 0 K | — |
| strrchravx2 | — | 0 K | 0 K | — |
| wcslen | — | 0 K | 0 K | — |
| expf | — | 0 K | 0 K | — |
| strncpy | — | 0 K | 0 K | — |
| iodefaultfinish | — | 0 K | — | — |
| stpncpy | — | 0 K | 0 K | — |
| wcsnlen | — | 0 K | 0 K | — |
| lseek | — | 0 K | — | — |
| stpcpy | — | 0 K | 0 K | — |
| strcpy | — | 0 K | 0 K | — |
| iofilesetbuf | — | 0 K | 0 K | — |
| strcat | — | 0 K | 0 K | — |
| strchravx2 | — | 0 K | — | — |
| popcountdi2 | — | 0 K | 0 K | — |
| wcsncpy | — | 0 K | 0 K | — |
| wcpncpy | — | 0 K | 0 K | — |
| tlspreinittp | — | 0 K | 0 K | — |
| wcscat | — | 0 K | 0 K | — |
| securityinit | — | 0 K | 0 K | — |
| wcscpy | — | 0 K | 0 K | — |
| initfirst | — | 0 K | 0 K | — |
| versioncheckdoit | — | 0 K | 0 K | — |
| dlhandleexecstacktunable | — | 0 K | 0 K | — |
| dldebugchangestate | — | 0 K | 0 K | — |
| dlsortmapsinit | — | 0 K | 0 K | — |
| pthreadcondinit | — | 0 K | — | — |
| clone3 | — | 0 K | 0 K | — |
| checkstdfilesvtables | — | 0 K | 0 K | — |
| pthreadcondattrsetclock | — | 0 K | — | — |
| access | — | 0 K | 0 K | — |
| printfbuffertofiledone | — | — | 0 K | — |
| cos | — | 0 K | 0 K | — |
| sinh | — | 0 K | 0 K | — |
| log2f | — | 0 K | 0 K | — |
| sinf | — | 0 K | 0 K | — |
| atanhfinite@glibc2.15 | — | 0 K | 0 K | — |
| logf | — | 0 K | 0 K | — |
| sincosf | — | 0 K | 0 K | — |
| log1p | — | 0 K | 0 K | — |
| atan | — | 0 K | 0 K | — |
| exp2f | — | 0 K | 0 K | — |
| dlauditpreinit | — | 0 K | 0 K | — |
| cosh | — | 0 K | 0 K | — |
| expm1 | — | 0 K | 0 K | — |
| cosf | — | 0 K | 0 K | — |
| logfinite@glibc2.15 | — | 0 K | 0 K | — |
| expfinite@glibc2.15 | — | 0 K | 0 K | — |
| log2 | — | 0 K | 0 K | — |
| rtldmallocinitstubs | — | 0 K | 0 K | — |
| tan | — | 0 K | 0 K | — |
| powf | — | 0 K | 0 K | — |
| sin | — | 0 K | 0 K | — |
| atan2finite@glibc2.15 | — | 0 K | 0 K | — |
| printfbuffertofileinit | — | — | 0 K | — |
| gsoutbytes | — | 0 K | — | — |
| dlcountmodids | — | 0 K | 0 K | — |
| exit | — | 0 K | 0 K | — |
| dlcetsetupfeatures | — | 0 K | 0 K | — |
| closenocancel | — | 0 K | — | — |
| asinfinite@glibc2.15 | — | 0 K | 0 K | — |
| sincos | — | 0 K | 0 K | — |
| iounsavemarkers | — | 0 K | — | — |
| dlauditactivitymap | — | 0 K | 0 K | — |
| powfinite@glibc2.15 | — | 0 K | 0 K | — |
| acosfinite@glibc2.15 | — | 0 K | 0 K | — |
| strspn | — | 0 K | 0 K | — |
| floorf | — | 0 K | 0 K | — |
| floor | — | 0 K | 0 K | — |
| roundeven | — | 0 K | 0 K | — |
| ceilf | — | 0 K | 0 K | — |
| strpbrk | — | 0 K | 0 K | — |
| vprintfchk | — | — | 0 K | — |
| trunc | — | 0 K | 0 K | — |
| ceil | — | 0 K | 0 K | — |
| roundevenf | — | 0 K | 0 K | — |
| truncf | — | 0 K | 0 K | — |
| fmaf | — | 0 K | 0 K | — |
| tunableisinitialized | — | 0 K | 0 K | — |
| fma | — | 0 K | 0 K | — |
| x86cpufeatures | — | 0 K | 0 K | — |
| strtol | — | — | 0 K | — |
| iofileseek | — | 0 K | — | — |
| ionewfileinitinternal | — | 0 K | — | — |
| gsosargcount | — | 0 K | — | — |
| pthreadcondattrinit | — | 0 K | — | — |
| iofilefinish | — | 0 K | — | — |
| dlx86initcpufeatures | — | 0 K | 0 K | — |
| dldebugstate | — | 0 K | 0 K | — |
| iounlink | — | 0 K | — | — |
| fopen | — | 0 K | — | — |
| cxaatexit | — | 0 K | 0 K | — |
| iofilestat | — | 0 K | 0 K | — |
| pthreadcondattrdestroy | — | 0 K | — | — |
| iofileclose | — | 0 K | — | — |
| dlsysdepstartcleanup | — | 0 K | 0 K | — |
