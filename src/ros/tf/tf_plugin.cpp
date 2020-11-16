
#include <knowrob/ros/tf/memory.h>
#include <knowrob/ros/tf/logger.h>
#include <knowrob/ros/tf/publisher.h>
#include <knowrob/ros/tf/republisher.h>

static ros::NodeHandle node;
static TFMemory memory;
static TFPublisher pub(memory);

TFLogger& get_logger() {
	static TFLogger logger(node,memory);
	return logger;
}

TFRepublisher& get_republisher() {
	static TFRepublisher republisher;
	return republisher;
}

// tf_republish_set_goal(DBName,CollectionName,Time0,Time1)
PREDICATE(tf_republish_set_goal, 4) {
	std::string db_name((char*)PL_A1);
	std::string coll_name((char*)PL_A2);
	double time_min = (double)PL_A3;
	double time_max = (double)PL_A4;
	get_republisher().set_db_name(db_name);
	get_republisher().set_db_collection(coll_name);
	get_republisher().set_goal(time_min,time_max);
	return true;
}

// tf_republish_set_loop(RealtimeFactor)
PREDICATE(tf_republish_set_loop, 1) {
	get_republisher().set_loop((int)PL_A1);
	return true;
}

// tf_republish_set_realtime_factor(RealtimeFactor)
PREDICATE(tf_republish_set_realtime_factor, 1) {
	double realtime_factor = (double)PL_A1;
	get_republisher().set_realtime_factor(realtime_factor);
	return true;
}

// tf_logger_enable
PREDICATE(tf_logger_enable, 0) {
	get_logger();
	return true;
}

// tf_logger_set_db_name(DBName)
PREDICATE(tf_logger_set_db_name, 1) {
	std::string db_name((char*)PL_A1);
	get_logger().set_db_name(db_name);
	return true;
}

//
PREDICATE(tf_logger_set_time_threshold, 1) {
	get_logger().set_time_threshold((double)PL_A1);
	return true;
}
PREDICATE(tf_logger_set_vectorial_threshold, 1) {
	get_logger().set_vectorial_threshold((double)PL_A1);
	return true;
}
PREDICATE(tf_logger_set_angular_threshold, 1) {
	get_logger().set_angular_threshold((double)PL_A1);
	return true;
}

//
PREDICATE(tf_logger_get_time_threshold, 1) {
	PL_A1=get_logger().get_time_threshold();
	return true;
}
PREDICATE(tf_logger_get_vectorial_threshold, 1) {
	PL_A1=get_logger().get_vectorial_threshold();
	return true;
}
PREDICATE(tf_logger_get_angular_threshold, 1) {
	PL_A1=get_logger().get_angular_threshold();
	return true;
}

// tf_mem_set_pose(ObjFrame,PoseData,Since)
PREDICATE(tf_mem_set_pose, 3) {
	std::string frame((char*)PL_A1);
	double stamp = (double)PL_A3;
	return memory.set_pose_term(frame,PL_A2,stamp);
}

// tf_republish_set_pose(ObjFrame,PoseData)
PREDICATE(tf_republish_set_pose, 2) {
	std::string frame((char*)PL_A1);
	get_republisher().memory().set_pose_term(frame,PL_A2,0.0);
	return true;
}

// tf_mem_get_pose(ObjFrame,PoseData,Since)
PREDICATE(tf_mem_get_pose, 3) {
	std::string frame((char*)PL_A1);
	double stamp;
	PlTerm pose_term;
	if(memory.get_pose_term(frame,&pose_term,&stamp)) {
		PL_A2 = pose_term;
		PL_A3 = stamp;
		return true;
	}
	return false;
}

// tf_mng_store(ObjFrame,PoseData,Since)
PREDICATE(tf_mng_store, 3) {
	std::string frame((char*)PL_A1);
	double stamp = (double)PL_A3;
	geometry_msgs::TransformStamped ts;
	memory.create_transform(&ts,frame,PL_A2,stamp);
	get_logger().store(ts);
	return true;
}
