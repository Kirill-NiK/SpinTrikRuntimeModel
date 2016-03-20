/* моделируем исполнение скрипта, начиная с run.
 по мере моделирования, будем дополнять модель другими процессами
 или просто расширять */
 
 /* enum State */
 #define ready 0
 #define starting 1
 #define stopping 2
 #define running 3
 /* с этими предположениями о миксимальном кол-ве скриптов/тредов надо быть осторожным 256? */
 #define N 1024 
 #define mutex bit
 
#ifndef NO_LOGGING
 #define LOG(x) printf(x)
#else
 #define LOG(x)
#endif
 
int mMaxScriptId = 0; /* поле mMaxScriptId в trikScriptRunner */
bool fileNameisEmpty = true; /* для файла, передаваемого в запуске TrikScriptRunner::run */
byte mState = ready; /* ScriptEngineWorker:state -> делать ли его локальным? */
int mFinishedThreads[N]; /* список завершившихся тредов - у меня будут инты, в проге - стринги */
int mPreventFromStart[N]; /* список тредов, которые ещё не были запущены, но должны быть завершены - у меня будут инты, в проге - стринги */
mutex mResetMutex = 1; /* мьютекс для mResetStarted; поскольку все операции с тредами должны быть атомарными */
bool mResetStarted = false; /*флаг, показывающий, что начался reset, во время которого все остальные операции с тредами должны отменяться; */
int mThreads[N]; /* хэш (который мы моделируем как массив), отображающий имя треда на сам тред, используется для получения доступа к отдельным потокам; */
int mThreadsCount = 0; /* кол-во потоков для mThreads */
mutex mThreadsMutex = 1; /* для mFinishedThreads, mPreventFromStart, mThreads  */


/* Каким образом организовано помещение в поток ??? */
/* Каким образом смоделировать сигнал-слот? (Паттерн наблюдатель?) - синхронно? то есть если коннект 2 раза сделать, то как обходить будет сигнал? */
/* Может стоит на месте QLOG_INFO() писать printf() с выводом той же информации? получится ли так везде и есть ли это хорошая цель? */
/* можно ставить лишшние метки для некоторых ничегонеделающих функций, чтоб проверять, что они вызывались ограниченное число раз */
/* Предполагаем, что Qt вызовы работают без ошибок - или сделать процесс заглушку? */

mtype = {startedScript }; /* попробуем тут располагать сигналы! */

chan signals = [0] of {mtype, int}; /* пытаемся моделировать сигналы, если несколько коннектов, то несколько раз и вызываем !&? */

/* присвоить всем элементам массива 0 -??????????? */
inline clear(_array) 
{
	_array = 0;
}

inline lock(_s)
{
	atomic{(_s > 0) -> _s--;}
}

inline unlock(_s)
{
	atomic{_s++;}
}

proctype engineThread()
{
	// тут где-то должен меняться mThreadsCount или посылаться нужный сигнал 
}

proctype mWorkerThread(int _scriptID) /* id скриптов нам полезны, вроде как */
{
	int mScriptId;
	mState = starting;
	mScriptId = _scriptID;
	signals ! startedScript, scriptId;
	
	/* ScriptEngineWorker::doRun */

	/* Threading::startMainThread внутри doRun*/
	clear(mFinishedThreads);
	clear(mPreventFromStart);
	
	/* Threading::startThread */
	
	lock(mResetMutex);

	if
	::	mResetStarted ->
		delete_engine: skip; /* можно проверять, что engine не вызывается после этой метки */
		unlock(mResetMutex);
		goto returnFromStartThread;
	:: else -> skip;
	fi

	lock(mThreadsMutex);
	if 
	::	(mThreads[threadId] == 1) ->
		threadId_abort: skip; /* тут останавливается работа скрипта и вызывается сигнал stopRunning, возможно его стоит посылать */
		unlock(mThreadsMutex);
		unlock(mResetMutex);
		goto returnFromStartThread;
	:: skip;
	fi

	if
	::	(mPreventFromStart[threadId] == 1) -> /* mPreventFromStart.contains(threadId) */
		mPreventFromStart[threadId] = 0; /* remove from mPreventFromStart threadId */
		mFinishedThreads[threadId] = 1; /* insert mFinishedThreads */
		unlock(mThreadsMutex);
		unlock(mResetMutex);
		goto returnFromStartThread;
	:: skip;
	fi

	//ScriptThread * const thread = new ScriptThread(*this, threadId, engine, script);
	//connect(&mScriptControl, SIGNAL(quitSignal()), thread, SIGNAL(stopRunning()), Qt::DirectConnection);
	atomic {mThreads[threadId] = 1; mThreadsCount++}; /* можно самому генерировать счетчик i для номеров тредов или ставить 1-0 ... */
	mFinishedThreads[threadId] = 0;
	unlock(mThreadsMutex);

	// connect(thread, SIGNAL(finished()), thread, SLOT(deleteLater()));
	run engineThread();

	// finite cicle removed
	QThread_yieldCurrentThread_500: skip; /* yieldCurrentThread - нужно ли моделировать в PROMELA */

	unlock(mResetMutex);	
	
	returnFromStartThread: mState = running;

	(mThreadsCount == 0); /* блокируем процесс, пока все потоки не завершатся*/
	
	/*тут сигнал, на сигнал вешается: 1) выход из приложения для скрипта из консоли - не важно? 2) метка brick->reset() */
	brik_reset: skip;
	
	
}

proctype GUIThread()
{
	
/* создаем объект */

//	connect(&mWorkerThread, SIGNAL(finished()), mScriptEngineWorker, SLOT(deleteLater()));
//	connect(&mWorkerThread, SIGNAL(finished()), &mWorkerThread, SLOT(deleteLater()));
//	connect(mScriptEngineWorker, SIGNAL(completed(QString, int)), this, SIGNAL(completed(QString, int)));
//	connect(mScriptController.data(), SIGNAL(sendMessage(QString)), this, SIGNAL(sendMessage(QString)));

/* вызывается TrikScriptRunner::run */

	mMaxScriptId++;
	workerStopScript: skip; /* ScriptEngineWorker::stopScript - а если остановится? - надо поправить */
	/* удалил действия связанные с файлом, они не могут повлиять на модель - максимумум вызывается виджет */
	run mWorkerThread(mMaxScriptId - 1); /* в нем будет вызовы соответсвующие для ScriptEngineWorker */
	
	/* ниже переносим коннекты, возможно, стоит перед перечислением добавить метку end */
	int x;
	do
	:: signals ? startedScript, x; /* потом вызываются сигналы, приводящие к вызыванию виджета */
	od
}

init 
{
	run GUIThread();
}