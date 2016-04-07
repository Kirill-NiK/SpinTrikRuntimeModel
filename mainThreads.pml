//#define NO_LOGGING // только для QLOG_INFO()
#define S 25 // максимальное количество запущенных скриптов (engineThreads) S < 256
#define N 50 // максимальная длина очереди event-ов для каждого потока N < 256

#ifndef NO_LOGGING
 #define LOG(x) printf(x); printf("\n")
#else
 #define LOG(x) skip
#endif

 /* enum State */
 #define ready 0
 #define starting 1
 #define stopping 2
 #define running 3
 
#define mutex bit

int mMaxScriptId = 0; /* поле mMaxScriptId в trikScriptRunner */
byte mState = ready; /* ScriptEngineWorker:state */
bool mInEventDrivenMode = false; /* находится в ScriptExecutionControl, True, if a system is in this mode, so it shall wait for events when script is executed. (c) */
mutex mResetMutex = 1; /* мьютекс для mResetStarted; поскольку все операции с тредами должны быть атомарными */
bool mResetStarted = false; /* флаг, показывающий, что начался reset, во время которого все остальные операции с тредами должны отменяться; */
mutex mThreadsMutex = 1; /* для mFinishedThreads, mPreventFromStart, mThreads  */
bit mFinishedThreads[S] = 0; /* список завершившихся тредов - у меня будут инты, в проге - стринги */
bit mPreventFromStart[S] = 0; /* список тредов, которые ещё не были запущены, но должны быть завершены - у меня будут инты, в проге - стринги */
bit mThreads[S] = 0; /* хэш (который мы моделируем как массив), отображающий имя треда на сам тред, используется для получения доступа к отдельным потокам; */

byte threadId = 0; /* имя треда, для :main: engine thread - 0, нужен только для модели, равен самому левому нулевому значению в mThreads */

mtype {emptyEvent, INVOKEdoRun, completed, start, runScript, abortScript, stopRunning, stopWaiting }; /* используемые сигналы-события для всех потоков, параметры - в глобальные переменные */
chan GUIThreadEvents = [N] of {mtype};
chan connectionThreadEvents = [N] of {mtype};
chan sensorsThreadEvents = [N] of {mtype};
chan scriptWorkerThreadEvents = [N] of {mtype};
chan engineThreadEvents [S] = [N] of {mtype};

bit abortEvaluationInvoked[S] = 0; /* массив, который обозначает, что engine->abortEvaluation() была вызвана. */

// pid engineThreads [S] = 0; /* массив, содержащий _pid engine тредов в модели, которые запущены, совместная работа с mThreads */ // добавить как значение run
byte mThreadCount = 0;

inline emit(thread, signal) /* в очередь событий \a thread добавить сигнал (событие) \a signal */
{
	//assert(nfull(thread)); /* Если копятся ивенты, значит что-то пошло не так... */
	thread ! signal;
}

inline lock(_s)
{	
	atomic {assert(_s == 1); _s--;}
}

inline unlock(_s)
{
	atomic {assert(_s == 0); _s++;}
}

inline random(min, max, x)
{
	atomic {
		assert(min <= max);
		x = min;
		do
		:: (x < max) -> 
			if
			:: break;
			:: skip;
			fi;
			x++;
		:: else -> break;
		od;
	}
}

inline tryLockReset() /* Threading::tryLockReset() */
{
	lock(mResetMutex);
	if
	:: mResetStarted -> unlock(mResetMutex);
	:: else -> skip;
	fi;
}

inline joinThread() // можно придумать 2-3 класса threadId?
{
	true -> joinThread_call: skip;
	byte tmp;
	random(-1, S - 1, tmp);
	
	lock(mThreadsMutex);
	do
	:: // какое-то длинное условие, на которое я забил. !mThreads[threadId]->isRunning() - я моделирую цельно. но возможно, стоит добавить isRunning[S]
		unlock(mThreadsMutex);
		if 
		:: mResetStarted -> goto joinThread_return;
		:: else -> skip;
		fi;
		lock(mThreadsMutex);
	:: (tmp != -1) -> break; /* крутимся цикле, пока не будет reset-а */
	od;
	
	if // mFinishedThreads.contains(threadId)
	:: unlock(mThreadsMutex); goto joinThread_return;
	:: skip;
	fi;

	unlock(mThreadsMutex);
	!mThreads[tmp]; // ОПАСНО: вообще, это неаккуратно, вдруг на mThreads[tmp] запишется другой тред
	//, а join в моей модели будет ждать, а в системе - нет.
	// за массив от [S] можно "убрать" эту неаккуратность
	joinThread_return: skip;	
}

inline abort(thrId)
{
	abortEvaluationInvoked[thrId] = 1;
	emit(engineThreadEvents[thrId], stopRunning);
}

inline killThread()
{
	true -> killThread_call: skip;
	tryLockReset();
	if 
	:: mResetStarted -> goto killThread_return;
	:: else -> skip;
	fi;
	lock(mThreadsMutex);
	
	byte tmp;
	random(-1, S - 1, tmp);
	
	if
	:: (tmp == -1) || (!mThreads[tmp]) -> // проверить, что при tmp==-1 будет всё ок.
		if // mFinishedThreads.contains(threadId)
		:: LOG("Threading: killing thread that is not started yet will be prevented from running");
		// mPreventFromStart.insert(threadId);
		:: LOG("Threading: killing already finished thread, ignoring");
		fi;
	:: else ->
		LOG("Threading: killing thread threadId");
		/* ScriptThread::abort() */ // перенести в необходимые места соответсвенно.
		abort(tmp);
	fi;
	
	unlock(mThreadsMutex);
	unlock(mResetMutex);
	killThread_return: skip;
}

inline clear(_arr, _len) // может атомик сделать?
{
	assert(_len > 0);
	byte i = 0;
	do
	:: i < _len -> _arr[i] = 0; i++;
	:: i == _len -> break;
	od;
}

inline threading_reset() // возможно из-за меток нельзя переиспользовать.
{
	true -> threading_reset_call: skip;
	tryLockReset();
	if 
	:: mResetStarted -> goto threading_reset_return;
	:: else -> skip;
	fi;
	mResetStarted = true;
	unlock(mResetMutex);
	LOG("Threading: reset started");
	// mMessageMutex.lock(); ... blah blah; mMessageMutex.unlock(); - пока не знаю, надо ли моделировать, но не стоит забывать
	lock(mThreadsMutex);
	// ВНИМАНИЕ: по всем тредам делать это: (до ***) можно эмулировать через массив [S], забив на очередь. а можно посылать сигналы на каждый из [S] тредов
	mInEventDrivenMode = false;
	// emit stopWaiting(); чтобы делать эмит, надо знать, куда посылать, а реализовать нужно - direct connect на прерывание лупа
	// stop, delete, clear timers
	// abort(?); ***
	clear(mFinishedThreads, S);
	unlock(mThreadsMutex);
	mThreadCount == 0; /* waitForAll(); */
	// много удалений, связанных с очередями сообщений
	LOG("Threading: reset ended");
	mResetStarted = false;
	threading_reset_return: skip;
}

inline brick_reset() // возможно из-за меток нельзя переиспользовать.
{
	LOG("Stopping brick");
	brikReset: skip; /* остановка по всем сенсорам, дисплею...*/
	do // должно дополняться любыми INVOKE-ами, отправленными к GUIWorker-у
	 // :: перебираем все ивенты в лупе и посылаем обратно. заводим счетчик до 0. если сигналы определенного типа, не посылаем, но уменьшаем счетчик. 
	:: break; // если счетчик равняется 0
	od;
}

inline stopScript() // возможно из-за меток нельзя переиспользовать.
{
	true -> stopScript_call: skip; 
	if
	:: mState == stopping -> goto stopScript_return;
	:: mState == ready -> goto stopScript_return;
	:: mState == running -> skip;
	:: mState == starting -> mState != starting; /* -> mState != starting означает цикл, ожидание */
	// Some script is starting right now, so we are in inconsistent state. Let it start, then stop it. (с)
	fi;
	LOG("ScriptEngineWorker: stopping script");
	mState = stopping;
	/* mScriptControl.reset(); */
	reset_call: skip;
	mInEventDrivenMode = false;
	// emit stopWaiting(); чтобы делать эмит, надо знать, куда посылать, а реализовать нужно - direct connect на прерывание лупа
	// stop, delete, clear timers
	reset_return: skip;
	// 	if (mMailbox) ... умышленно забиваем
	/* Threading::reset() */
	threading_reset();
	// if (mDirectScriptsEngine) - забиваем на runDirect пока что
	mState = ready;
	LOG("ScriptEngineWorker: stopping complete");
	stopScript_return: skip;
}

inline findFreeThreadId() /* только тут меняется threadId и он равен или -1 или самому левому индексу в mThreads, который не занят */
{
	byte i = 0;
	do
	:: i < S && mThreads[i] == 1 -> i++;
	:: i < S && mThreads[i] == 0 -> threadId = i; break;
	:: i == S -> threadId = -1; break;
	od;
}

// правильность меток? может, "spin -I > afterPreproc.txt" и глянуть, как они обрабаываются в inline? + посмотреть документацию по C
inline startThread() /* в этом методе не важно, что за имя треда и функции нам передают, поэтому выбираем недетерминированно */
{
	true -> startThread_call: skip;
	
	byte tmp;
	random(-1, S - 1, tmp);
	
	lock(mResetMutex);
	if
	:: mResetStarted ->
		LOG("Threading: can't start new thread due to reset"); 
		delete_engine: skip;
		unlock(mResetMutex);
		goto startThread_return;
	:: else -> skip;
	fi;
	lock(mThreadsMutex);
	if 
	:: (tmp != -1) && (mThreads[tmp]) -> // проверить, что при tmp==-1 будет всё ок. /* если тред такой уже существует */
		LOG("Threading: attempt to create a thread with an already occupied id");
		abort(tmp);
		unlock(mThreadsMutex);
		unlock(mResetMutex);
		goto startThread_return;
	:: else -> skip;
	fi;
	if
	:: true -> /* если пытались ранее убить незапущенный тред */
		LOG("Threading: attempt to create a thread which must be killed");
		// prevent ... это важно?
		// finished ... это важно?
		unlock(mThreadsMutex);
		unlock(mResetMutex);
		goto startThread_return;
	:: true -> skip;
	fi;
	LOG("Starting new thread with engine");
	// connect(&mScriptControl, SIGNAL(quitSignal()), thread, SIGNAL(stopRunning()), Qt::DirectConnection);
	byte myThread;
	atomic {threadId != -1; /* искусственно запрещаем создавать больше S тредов */ // может goto на выход сделать при -1?
		myThread = threadId;
		mThreads[myThread] = 1;
		abortEvaluationInvoked[myThread] = 0;
		mThreadCount++;
		assert(mThreadCount <= S); /* Изначально мы считаем, что максимальное количество запущенных потоков engineThread ограничено */
		assert(mThreadCount >= 1)
		findFreeThreadId(); };
	mFinishedThreads[myThread] = 0;
	unlock(mThreadsMutex);
	run engineThread(myThread);
	// connect(thread, SIGNAL(finished()), thread, SLOT(deleteLater())); - надо ли?
	emit(engineThreadEvents[myThread], start); /* Мы переопределяли run(), поэтому отдельно расписываем thread->start() */
	LOG("Threading: started thread with engine thread object");
	unlock(mResetMutex);
	startThread_return: skip;
}

inline script_quit()
{
	skip;
	// emit quitSignal(); - соединяется с сигналом и слотом
	// connect(&mScriptControl, SIGNAL(quitSignal()), this, SLOT(onScriptRequestingToQuit()));
	// connect(&mScriptControl, SIGNAL(quitSignal()), thread, SIGNAL(stopRunning()), Qt::DirectConnection); stopWaiting[x] = 1;
}

inline script_run()
{
	mInEventDrivenMode = true;
}

inline script_wait(x) // когда этот метод взаимодействует с методом script_quit?
{
	// stopWaiting[x] = 0;
	skip; // stopWaiting[x]; можно сделать процесс таймер, который будет ставить stopWaiting[x] = 1; или скипать в цикле.
}

proctype sensorsThread() /* На самом деде существует много отдельных потоков для различных сенсоров */
{
	mtype signal;
	progress1: do
	:: sensorsThreadEvents ? signal ->
		if
		:: signal == emptyEvent -> skip;
	    fi;
	od;
}

proctype connectionThread()
{
	mtype signal;
	progress2: do
	:: connectionThreadEvents ? signal ->
		if
		:: signal == emptyEvent -> skip;
	    fi;
	od;
}

// главный тред знает что-то о порожденных?
proctype engineThread(byte id) /* id остаётся одинаковым на всё время жизни треда */
{
	assert(_pid <= S); /* Изначально мы считаем, что максимальное количество запущенных потоков engineThread ограничено */ // - _pid - не для всей модели? 
	mtype signal;
	progress3: do
	:: engineThreadEvents[id] ? signal ->
		if
		:: signal == emptyEvent -> skip;
		:: signal == start -> /* ScriptThread::run() */
			LOG("Started thread ScriptThread");
			evaluate_call: skip; /* mEngine->evaluate(mScript) */
			/* скрипт внутри может вызвать новые потоки, убивать... */
			// сделать соответствующий недетерминированный выбор, только с ограничением на вызов, важный момент при q_invokable коннект direct?
			do /* в данной модели забиваем тут на brick, gamepad, mailbox из createScriptEngine */
			// ещё тут можно ловить сигналы мб? для аборта или проверку сделать на глобал переменную? - для прерываний от пользователя.
			:: (!abortEvaluationInvoked[id]) ->
				:: true -> startThread(); /* параметр моделируем через недетерминизм, кол-во тредов ограничиваем сами или run()-ом */ // копирование engine не важно же - зачем evalute?
				:: true -> joinThread(); /* параметр моделируем через недетерминизм */
				:: true -> killThread(); /* параметр моделируем через недетерминизм */
				// :: sendMessage();
				// :: receiveMessage();
				// ALARM! можно испускать сигналы из ScriptExecutionControl.
				:: true -> script_quit();
				:: true -> script_run();
				:: true -> script_wait(id);
				:: break; /* конец скрипта */
			:: else -> break;
			od;
			evaluate_return: skip;
			if
			:: true -> LOG("Uncaught exception at line");
			// :: mInEventDrivenMode -> emit(engineThreadEvents, stopRunning); stopRunningIsEmitted[_pid]; поставить проверку, что сигнал словлен, без этого не пускать.
			:: skip;
			fi;
			// mEngine->deleteLater(). можно послать соответствующий сигнал. который на обработке просто поставит метку deleted. - вообще мб удаление именно стоит проверить?
			LOG("Finishing thread id");
			lock(mResetMutex);
			lock(mThreadsMutex);
			LOG("Thread id has finished, thread object ...");
			atomic {mThreads[id] = 0; 
				findFreeThreadId();
				assert(empty(engineThreadEvents[id])); // это ведь плохо, если перед удалением у нас висят какие-то ивента в ивентлупе?...
				mThreadCount--;
				}
			mFinishedThreads[id] = 1; // FIXME: тут если в цикле создаются треды и тут же удаляются?
			unlock(mThreadsMutex);
			unlock(mResetMutex);
			if
			:: threading_reset();
			:: skip;
			fi;
			LOG("Ended evaluation, thread ScriptThread");
	    fi;
	od;
}

proctype scriptWorkerThread()
{
	mtype signal;
	progress4: do
	:: scriptWorkerThreadEvents ? signal ->
		if 
	    :: signal == emptyEvent -> skip;
		:: signal == INVOKEdoRun -> 
			clear(mFinishedThreads, S);
			clear(mPreventFromStart, S);
			startThread_call: skip;
			lock(mResetMutex);
			if
			:: mResetStarted ->
				LOG("Threading: can't start new thread due to reset"); 
				delete_engine: skip;
				unlock(mResetMutex);
				goto startThread_return;
			:: else -> skip;
			fi;
			lock(mThreadsMutex);
			if 
			:: mThreads[threadId] == 1 ->
				LOG("Threading: attempt to create a thread with an already occupied id");
				abort(threadId);
				unlock(mThreadsMutex);
				unlock(mResetMutex);
				goto startThread_return;
			:: else -> skip;
			fi;
			if
			:: mPreventFromStart[threadId] == 1 ->
				LOG("Threading: attempt to create a thread which must be killed");
				mPreventFromStart[threadId] = 0;
				mFinishedThreads[threadId] = 1;
				unlock(mThreadsMutex);
				unlock(mResetMutex);
				goto startThread_return;
			:: else -> skip;
			fi;
			LOG("Starting new thread with engine");
			// connect(&mScriptControl, SIGNAL(quitSignal()), thread, SIGNAL(stopRunning()), Qt::DirectConnection);
			mThreads[threadId] = 1;
			mFinishedThreads[threadId] = 0;
			unlock(mThreadsMutex);
			atomic {mThreadCount++;
				assert(mThreadCount <= S); /* Изначально мы считаем, что максимальное количество запущенных потоков engineThread ограничено */
				assert(mThreadCount >= 1);
				assert(threadId == 0); /* так как тут создается только <<main>> engine */
				run engineThread(threadId);
				findFreeThreadId();}
			// connect(thread, SIGNAL(finished()), thread, SLOT(deleteLater())); - надо ли?
			emit(engineThreadEvents[threadId], start); /* Мы переопределяли run(), поэтому отдельно расписываем thread->start() */
			LOG("Threading: started thread with engine thread object");
			unlock(mResetMutex);
			startThread_return: skip;
			waitForAll_call: skip;
			mThreadCount == 0 ->
			waitForAll_return: skip;
			LOG("ScriptEngineWorker: evaluation ended with message, empty or error");
			emit(GUIThreadEvents, completed);
		fi;
	od;
}

proctype GUIThread()
{
	mtype signal;
	progress5: do
	:: GUIThreadEvents ? signal -> /* расписываем ВСЕ возможные сигналы */
		if
		:: signal == runScript -> 
			LOG("TrikGui started");
			run connectionThread(); /* создается с backgroundwidget */
			run sensorsThread(); /* создается с brick */
			// подумать, что делать с удалением через signal finished
			LOG("Starting TrikScriptRunner worker thread");
			run scriptWorkerThread();
			/* TrikScriptRunner::run */
			mMaxScriptId++; // вроде нигде не понадобится для данной модели. удалить?
			LOG("TrikScriptRunner: new script");
			/* вызывается mScriptEngineWorker->stopScript() */
			stopScript();
			/* startScriptEvaluation */
			LOG("ScriptEngineWorker: starting script");
			mState = starting;
			atomic {threadId = 0;
				emit(scriptWorkerThreadEvents, INVOKEdoRun);};
		:: signal == completed ->
			if
			:: true -> hideRunningWidgetSignal: skip;
			:: true-> sendMessages: skip; showErrorSignal: skip; /* по всем открытым соединениям вещается об ошибке */
			fi;
			brick_reset();
		:: signal == abortScript ->
			stopScript();
			LOG("Stopping robot");
			brick_reset();
	    fi;
	od;
}

proctype User() /* процесс, который моделирует возможные вызовы методов в trikScriptRunner */
{
	progress6: do
	:: emit(GUIThreadEvents, runScript); // точно ли надо через эмиты? может, глобальные переменные - как доставляется сигнал?
	:: emit(GUIThreadEvents, abortScript);
	od
}

init
{
	
	//run User();
	run GUIThread();
	emit(GUIThreadEvents, runScript);
}