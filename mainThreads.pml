//#define NO_LOGGING // только для QLOG_INFO()
#define S 50 // максимальное количество запущенных скриптов (engineThreads)
#define N 100 // максимальная длина очереди event-ов для каждого потока

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
bool fileNameisEmpty = true; /* для файла, передаваемого в запуске TrikScriptRunner::run */
byte mState = ready; /* ScriptEngineWorker:state -> делать ли его локальным? */
int mFinishedThreads[N]; /* список завершившихся тредов - у меня будут инты, в проге - стринги */
int mPreventFromStart[N]; /* список тредов, которые ещё не были запущены, но должны быть завершены - у меня будут инты, в проге - стринги */
mutex mResetMutex = 1; /* мьютекс для mResetStarted; поскольку все операции с тредами должны быть атомарными */
bool mResetStarted = false; /*флаг, показывающий, что начался reset, во время которого все остальные операции с тредами должны отменяться; */
int mThreads[N]; /* хэш (который мы моделируем как массив), отображающий имя треда на сам тред, используется для получения доступа к отдельным потокам; */
int mThreadsCount = 0; /* кол-во потоков для mThreads */
mutex mThreadsMutex = 1; /* для mFinishedThreads, mPreventFromStart, mThreads  */

inline lock(_s)
{
	atomic{(_s > 0) -> _s--;}
}

inline unlock(_s)
{
	atomic{_s++;}
}

mtype {emptyEvent, INVOKEdoRun, completed, start, stopRunning }; /* используемые сигналы-события для всех потоков, параметры - в глобальные переменные */
// может описывать сигналы?
chan GUIThreadEvents = [N] of {mtype};
chan connectionThreadEvents = [N] of {mtype};
chan sensorsThreadEvents = [N] of {mtype};
chan scriptWorkerThreadEvents = [N] of {mtype};
chan engineThreadEvents [S] = [N] of {mtype};
bit engineThreads [S] = 0; /* массив, отмечающий, что engine потоки запущены/не запущены */
// engineThreads можно использовать, но постоянно как-то менять массив, чтоб 111->101->110? а пока условимся, что удаляется последний всегда
byte mThreadCount = 0;

bool inEventDrivenMode = false; /* mThreading.inEventDrivenMode() */

inline emit(thread, signal) /* в очередь событий \a thread добавить сигнал (событие) \a signal */
{
	assert(nfull(thread)); /* Если копятся ивенты, значит что-то пошло не так... */
	thread ! signal;
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

inline startThread()
{
	true -> startThread_call_: skip;
	if
	:: LOG("Threading: can't start new thread due to reset"); goto startThread_return_;
	:: skip;
	fi;
	if 
	:: LOG("Threading: attempt to create a thread which must be killed"); goto startThread_return_;
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
			do /* в данной модели забиваем тут на brick, gamepad, mailbox из createScriptEngine */
			:: startThread(); /* тут надо понимать: или ограничивать или зависнет */ // не забыть смоделировать копирование engine!
			:: joinThread(); /* так как параметр любой, нет смысла что-то передавать */
			:: killThread(); /* так как параметр любой, нет смысла что-то передавать */
			// :: sendMessage();
			// :: receiveMessage();
			// для данной модели ещё 10 тысяч функций из script execution control - можно испускать сигналы, script.signal
			
			:: break;
			od;
			evaluate_return: skip;
			if
			:: true -> LOG("Uncaught exception at line");
			:: skip; // inEventDrivenMode -> emit(engineThreadEvents, stopRunning); stopRunningIsEmitted[_pid]; поставить проверку, что сигнал словлен, без этого не пускать.
			:: !inEventDrivenMode -> skip;
			fi;
			// mEngine->deleteLater(). можно послать соответствующий сигнал. который на обработке просто поставит метку deleted.
			LOG("Finishing thread id");
			// тут мьютексы
			LOG("Thread id has finished, thread object ...");
			atomic{assert(empty(engineThreadEvents[number - 1])); // это ведь плохо, если перед удалением у нас висят какие-то ивента в ивентлупе?...
			 mThreadCount--}; // надо как-то отслеживать номер удаляемого engineThread
			if
			:: skip; // Threading::reset();
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
			startThread_call: skip;
			if
			:: LOG("Threading: can't start new thread due to reset"); goto startThread_return;
			:: skip;
			fi;
			if 
			:: LOG("Threading: attempt to create a thread which must be killed"); goto startThread_return;
			:: skip;
			fi;
			if
			:: LOG("Threading: attempt to create a thread which must be killed"); goto startThread_return;
			:: skip;
			fi;
			LOG("Starting new thread with engine");
			atomic {mThreadCount++;
				assert(mThreadCount <= S); /* Изначально мы считаем, что максимальное количество запущенных потоков engineThread ограничено */
				assert(mThreadCount >= 1);
				run engineThread(mThreadCount);
				emit(engineThreadEvents[mThreadCount - 1], start);}; /* Мы переопределяли run(), поэтому отдельно расписываем thread->start() */
			LOG("Threading: started thread with engine thread object");
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
			LOG("TrikScriptRunner: new script");
			/* вызывается mScriptEngineWorker->stopScript() */
			LOG("ScriptEngineWorker: stopping script");
			if
			:: LOG("ScriptEngineWorker : ending interpretation");
			:: skip;
			fi;
			LOG("Threading: reset started");
			LOG("Threading: reset ended");
			LOG("ScriptEngineWorker: stopping complete");
			/* startScriptEvaluation */
			LOG("ScriptEngineWorker: starting script");
			emit(scriptWorkerThreadEvents, INVOKEdoRun);
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
		:: signal == completed ->
	    fi;
	od;
}

init
{
	run GUIThread();
	emit(GUIThreadEvents, emptyEvent);
	// попробовать смоделировать процесс user, который тупо прерывает процесс/запускает заново и т.д. без доп тредов и усложнения модели
}