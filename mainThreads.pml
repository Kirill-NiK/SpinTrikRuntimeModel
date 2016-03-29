//#define NO_LOGGING // только для QLOG_INFO()
#define S 25 // максимальное количество запущенных скриптов (engineThreads)
#define N 50 // максимальная длина очереди event-ов для каждого потока

#ifndef NO_LOGGING
 #define LOG(x) printf(x)
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

int threadId = 0; /* имя треда, для мейна - 0 */

mtype {emptyEvent, INVOKEdoRun, completed, start, stopRunning }; /* используемые сигналы-события для всех потоков, параметры - в глобальные переменные */
chan GUIThreadEvents = [N] of {mtype};
chan connectionThreadEvents = [N] of {mtype};
chan sensorsThreadEvents = [N] of {mtype};
chan scriptWorkerThreadEvents = [N] of {mtype};
chan engineThreadEvents [S] = [N] of {mtype};
bit engineThreads [S] = 0; /* массив, отмечающий, что engine потоки запущены/не запущены */
// engineThreads можно использовать, но постоянно как-то менять массив, чтоб 111->101->110? а пока условимся, что удаляется последний всегда
byte mThreadCount = 0;

inline emit(thread, signal) /* в очередь событий \a thread добавить сигнал (событие) \a signal */
{
	assert(nfull(thread)); /* Если копятся ивенты, значит что-то пошло не так... */
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

inline tryLockReset() /* Threading::tryLockReset() */
{
	lock(mResetMutex);
	if
	:: mResetStarted -> unlock(mResetMutex);
	:: else -> skip;
	fi;
}

inline startThread()
{
	true -> startThread_call_: skip;
	if
	:: LOG("Threading: can't start new thread due to reset"); goto startThread_return_;
	:: skip;
	fi;
	if 
	:: LOG("Threading: attempt to create a thread with an already occupied id"); goto startThread_return_;
	:: skip;
	fi;
	if
	:: LOG("Threading: attempt to create a thread which must be killed"); goto startThread_return_;
	:: skip;
	fi;
	LOG("Starting new thread with engine");
	atomic {mThreadCount++;
		assert(mThreadCount <= S); /* Изначально мы считаем, что максимальное количество запущенных потоков engineThread ограничено */
		assert(mThreadCount >= 1);
		run engineThread(mThreadCount); // можно получать возвращаемое значение от run и с ним придумывать что-то
		emit(engineThreadEvents[mThreadCount - 1], start);}; /* Мы переопределяли run(), поэтому отдельно расписываем thread->start() */
	LOG("Threading: started thread with engine thread object");
	startThread_return_: skip;
}

inline joinThread() // метки не работают
{
	// можно придумать 2-3 класса threadId?
	skip;
}

inline killThread()
{
	skip;
}

inline clear(_arr, _len)
{
	assert(_len > 0);
	byte i = 0;
	do
	:: i < _len -> _arr[i] = 0; i++;
	:: i == _len -> break;
	od;
}

inline threading_reset()
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
	// mEngine->abortEvaluation();
	// emit stopRunning(); ***
	clear(mFinishedThreads, S);
	unlock(mThreadsMutex);
	mThreadCount == 0; /* waitForAll(); */
	// много удалений, связанных с очередями сообщений
	LOG("Threading: reset ended");
	mResetStarted = false;
	threading_reset_return: skip;
}

proctype sensorsThread() /* На самом деде существует много отдельных потоков для различных сенсоров */
{
	mtype signal;
	progress: do
	:: sensorsThreadEvents ? signal ->
		if
		:: signal == emptyEvent -> skip;
	    fi;
	od;
}

proctype connectionThread()
{
	mtype signal;
	progress: do
	:: connectionThreadEvents ? signal ->
		if
		:: signal == emptyEvent -> skip;
	    fi;
	od;
}

proctype engineThread(byte number)
{
	assert(_pid <= S); /* Изначально мы считаем, что максимальное количество запущенных потоков engineThread ограничено */ // - _pid - не для всей модели? 
	mtype signal;
	progress: do
	:: engineThreadEvents[number - 1] ? signal ->
		if
		:: signal == emptyEvent -> skip;
		:: signal == start -> /* ScriptThread::run() */
			LOG("Started thread ScriptThread");
			evaluate_call: skip; /* mEngine->evaluate(mScript) */
			/* скрипт внутри может вызвать новые потоки, убивать... */
			// сделать соответствующий недетерминированный выбор, только с ограничением на вызов, важный момент при q_invokable коннект direct?
			do /* в данной модели забиваем тут на brick, gamepad, mailbox из createScriptEngine */ // можно атомарно увеличивать счетчик (кол-во команд), а потом break по else
			// ещё тут можно ловить сигналы мб? для аборта или проверку сделать на глобал переменную?
			//:: startThread(); /* тут надо понимать: или ограничивать или зависнет */ // не забыть смоделировать копирование engine!
			//:: joinThread(); /* так как параметр любой, нет смысла что-то передавать */
			//:: killThread(); /* так как параметр любой, нет смысла что-то передавать */
			// :: sendMessage();
			// :: receiveMessage();
			// для данной модели ещё 10 тысяч функций из script execution control - можно испускать сигналы, script.signal -wtf
			// quit();
			:: break;
			od;
			evaluate_return: skip;
			if
			:: true -> LOG("Uncaught exception at line");
			// :: mInEventDrivenMode -> emit(engineThreadEvents, stopRunning); stopRunningIsEmitted[_pid]; поставить проверку, что сигнал словлен, без этого не пускать.
			:: skip;
			fi;
			// mEngine->deleteLater(). можно послать соответствующий сигнал. который на обработке просто поставит метку deleted.
			LOG("Finishing thread id");
			lock(mResetMutex);
			lock(mThreadsMutex);
			LOG("Thread id has finished, thread object ...");
			// mThreads[] = 0; // в пустых скобках - mId(id)
			// mFinishedThreads[] = 1; // mId(id)
			unlock(mThreadsMutex);
			unlock(mResetMutex);
			atomic {assert(empty(engineThreadEvents[number - 1])); // это ведь плохо, если перед удалением у нас висят какие-то ивента в ивентлупе?...
				mThreadCount--}; // надо как-то отслеживать номер удаляемого engineThread
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
	progress: do
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
				//mEngine->abortEvaluation();
				//emit stopRunning(); для threadId
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
				run engineThread(mThreadCount); }
			// connect(thread, SIGNAL(finished()), thread, SLOT(deleteLater())); - надо ли?
			emit(engineThreadEvents[mThreadCount - 1], start); /* Мы переопределяли run(), поэтому отдельно расписываем thread->start() */
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
	progress: do
	:: GUIThreadEvents ? signal -> /* расписываем ВСЕ возможные сигналы */
		if
		:: signal == emptyEvent -> 
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
			stopScript_call: skip; 
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
			LOG("Stopping brick");
			brikReset: skip; /* остановка по всем сенсорам, дисплею...*/
			do // должно дополняться любыми INVOKE-ами, отправленными к GUIWorker-у
			 // :: перебираем все ивенты в лупе и посылаем обратно. заводим счетчик до 0. если сигналы определенного типа, не посылаем, но уменьшаем счетчик. 
			:: break; // если счетчик равняется 0
			od;
	    fi;
	od;
}

init
{
	run GUIThread();
	emit(GUIThreadEvents, emptyEvent);
	// попробовать смоделировать процесс user, который тупо прерывает процесс/запускает заново и т.д. без доп тредов и усложнения модели
}